// MongoDB seed / bootstrap script — run by the one-shot `mongo-seed` Compose
// service once `mongodb` is healthy (replica set has a writable primary). It is
// deliberately NOT a `/docker-entrypoint-initdb.d` script: those run before the
// replica set is initiated, so every write there fails with "not primary".
//
// Issue #70 domain cutover:
//   * introduces a seeded, read-only `devices` registry (server-room topology);
//   * re-shapes `sensor_readings` to the deviceId/channel schema with a BSON
//     `Date` timestamp.
//
// Bootstrap contract (fail-closed):
//   * fresh state (both collections absent/empty)  -> perform the deterministic seed
//   * fully initialised existing state             -> validate, exit 0, do NOT reseed
//   * partial / inconsistent / ambiguous state     -> print the reason, exit non-zero
//
// It never drops or reseeds a database that already holds data, and it never
// silently accepts a half-initialised state. A clean re-cutover is an explicit
// operator action: `docker compose down -v`.

// The registry the seed produces. Existing-state validation requires exactly
// these ids — no more, no fewer.
const EXPECTED_DEVICE_IDS = ["rack-a1", "rack-a2", "ups-1", "pdu-a1", "crac-1"];

// Index key specs that must exist on `sensor_readings` for a state to count as
// initialised.
const REQUIRED_READING_INDEXES = [
  { deviceId: 1, channel: 1, timestamp: -1 },
  { timestamp: -1 },
];

// --- issue #73: threshold alerting -----------------------------------------
// The approved, seeded rule set. Existing-state validation requires exactly
// these ids AND this config (the `description` text is not validated).
const EXPECTED_ALERT_RULES = [
  {
    _id: "rack-intake-temp-high",
    ruleId: "rack-intake-temp-high",
    enabled: true,
    match: { deviceId: null, deviceKind: "rack", channel: "intake_temp" },
    operator: ">",
    threshold: 30,
    clearThreshold: 27,
    severity: "warning",
    description: "Rack cold-aisle intake temperature is high",
  },
  {
    _id: "rack-humidity-high",
    ruleId: "rack-humidity-high",
    enabled: true,
    match: { deviceId: null, deviceKind: "rack", channel: "humidity" },
    operator: ">",
    threshold: 60,
    clearThreshold: 55,
    severity: "warning",
    description: "Rack relative humidity is high",
  },
  {
    _id: "crac-return-temp-high",
    ruleId: "crac-return-temp-high",
    enabled: true,
    match: { deviceId: "crac-1", deviceKind: null, channel: "return_temp" },
    operator: ">",
    threshold: 41,
    clearThreshold: 37,
    severity: "warning",
    description: "CRAC return-air temperature is high",
  },
  {
    _id: "ups-input-voltage-low",
    ruleId: "ups-input-voltage-low",
    enabled: true,
    match: { deviceId: "ups-1", deviceKind: null, channel: "input_voltage" },
    operator: "<",
    threshold: 180,
    clearThreshold: 210,
    severity: "critical",
    description: "UPS input voltage lost (mains failure)",
  },
  {
    _id: "ups-battery-low",
    ruleId: "ups-battery-low",
    enabled: true,
    match: { deviceId: "ups-1", deviceKind: null, channel: "battery_pct" },
    operator: "<",
    threshold: 95,
    clearThreshold: 98,
    severity: "critical",
    description: "UPS battery charge is low",
  },
];

// Index key specs that must exist on `alert_events` for the #73 alert schema to
// count as initialised.
const REQUIRED_ALERT_EVENT_INDEXES = [
  { state: 1, deviceId: 1, channel: 1 },
  { startedAt: -1 },
];

print("🚀 MongoDB bootstrap starting...");

// --- wait for a writable primary --------------------------------------------
for (let attempt = 0; attempt < 60; attempt++) {
  try {
    if (db.hello().isWritablePrimary) {
      break;
    }
  } catch (e) {
    // node still stepping up; retry
  }
  sleep(1000);
}
if (!db.hello().isWritablePrimary) {
  print("❌ replica set did not reach a writable primary in time");
  quit(1);
}

const databaseName = process.env.MONGO_INITDB_DATABASE;
if (!databaseName || databaseName.trim().length === 0) {
  print("❌ MONGO_INITDB_DATABASE must select an application database");
  quit(1);
}
db = db.getSiblingDB(databaseName);
print("📦 Database: " + db.getName());

// ---------------------------------------------------------------------------
// Seed data — single source for both the fresh seed and the completeness check.
// Do not change the approved topology (device ids / kinds / channels / units).
// ---------------------------------------------------------------------------

const RACK_CHANNELS = [
  { channel: "intake_temp", unit: "°C" },
  { channel: "exhaust_temp", unit: "°C" },
  { channel: "humidity", unit: "%" },
  { channel: "power_draw", unit: "W" },
  { channel: "fan_rpm", unit: "rpm" },
  { channel: "door_contact", unit: "state" },
];

const devices = [
  {
    _id: "rack-a1",
    deviceId: "rack-a1",
    name: "Rack A1",
    kind: "rack",
    location: "Server Room / Rack A1",
    channels: RACK_CHANNELS,
  },
  {
    _id: "rack-a2",
    deviceId: "rack-a2",
    name: "Rack A2",
    kind: "rack",
    location: "Server Room / Rack A2",
    channels: RACK_CHANNELS,
  },
  {
    _id: "ups-1",
    deviceId: "ups-1",
    name: "UPS 1",
    kind: "ups",
    location: "Server Room / Power",
    channels: [
      { channel: "load_pct", unit: "%" },
      { channel: "battery_pct", unit: "%" },
      { channel: "input_voltage", unit: "V" },
    ],
  },
  {
    _id: "pdu-a1",
    deviceId: "pdu-a1",
    name: "PDU A1",
    kind: "pdu",
    location: "Server Room / Rack A1",
    channels: [
      { channel: "power_draw", unit: "W" },
      { channel: "current", unit: "A" },
    ],
  },
  {
    _id: "crac-1",
    deviceId: "crac-1",
    name: "CRAC 1",
    kind: "crac",
    location: "Server Room / Cooling",
    channels: [
      { channel: "supply_temp", unit: "°C" },
      { channel: "return_temp", unit: "°C" },
      { channel: "fan_rpm", unit: "rpm" },
    ],
  },
];

// Deterministic recent seed: two samples per channel, five minutes apart.
const T0 = new Date("2026-09-10T08:00:00Z");
const T1 = new Date("2026-09-10T08:05:00Z");

function reading(deviceId, channel, unit, value, when) {
  return { deviceId, channel, value, unit, timestamp: when };
}

const readings = [
  // rack-a1
  reading("rack-a1", "intake_temp", "°C", 21.4, T0),
  reading("rack-a1", "intake_temp", "°C", 21.6, T1),
  reading("rack-a1", "exhaust_temp", "°C", 31.2, T0),
  reading("rack-a1", "exhaust_temp", "°C", 31.8, T1),
  reading("rack-a1", "humidity", "%", 42.0, T0),
  reading("rack-a1", "humidity", "%", 41.5, T1),
  reading("rack-a1", "power_draw", "W", 1180, T0),
  reading("rack-a1", "power_draw", "W", 1225, T1),
  reading("rack-a1", "fan_rpm", "rpm", 3200, T0),
  reading("rack-a1", "fan_rpm", "rpm", 3260, T1),
  reading("rack-a1", "door_contact", "state", "closed", T0),
  reading("rack-a1", "door_contact", "state", "closed", T1),

  // rack-a2
  reading("rack-a2", "intake_temp", "°C", 22.1, T0),
  reading("rack-a2", "intake_temp", "°C", 22.3, T1),
  reading("rack-a2", "exhaust_temp", "°C", 32.5, T0),
  reading("rack-a2", "exhaust_temp", "°C", 33.1, T1),
  reading("rack-a2", "humidity", "%", 43.2, T0),
  reading("rack-a2", "humidity", "%", 43.0, T1),
  reading("rack-a2", "power_draw", "W", 1340, T0),
  reading("rack-a2", "power_draw", "W", 1375, T1),
  reading("rack-a2", "fan_rpm", "rpm", 3400, T0),
  reading("rack-a2", "fan_rpm", "rpm", 3455, T1),
  reading("rack-a2", "door_contact", "state", "closed", T0),
  reading("rack-a2", "door_contact", "state", "open", T1),

  // ups-1
  reading("ups-1", "load_pct", "%", 38.0, T0),
  reading("ups-1", "load_pct", "%", 39.5, T1),
  reading("ups-1", "battery_pct", "%", 100.0, T0),
  reading("ups-1", "battery_pct", "%", 100.0, T1),
  reading("ups-1", "input_voltage", "V", 230.4, T0),
  reading("ups-1", "input_voltage", "V", 229.8, T1),

  // pdu-a1
  reading("pdu-a1", "power_draw", "W", 2360, T0),
  reading("pdu-a1", "power_draw", "W", 2415, T1),
  reading("pdu-a1", "current", "A", 9.8, T0),
  reading("pdu-a1", "current", "A", 10.1, T1),

  // crac-1
  reading("crac-1", "supply_temp", "°C", 18.0, T0),
  reading("crac-1", "supply_temp", "°C", 18.2, T1),
  reading("crac-1", "return_temp", "°C", 26.9, T0),
  reading("crac-1", "return_temp", "°C", 27.4, T1),
  reading("crac-1", "fan_rpm", "rpm", 2800, T0),
  reading("crac-1", "fan_rpm", "rpm", 2860, T1),
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function indexKeyString(key) {
  return JSON.stringify(key);
}

function hasRequiredIndex(collection, wantedKey) {
  const wanted = indexKeyString(wantedKey);
  return collection.getIndexes().some((ix) => indexKeyString(ix.key) === wanted);
}

// Returns a list of human-readable reasons the current persisted state is not a
// complete, consistent #70 initialisation. Empty list == fully initialised.
function completenessProblems() {
  const problems = [];

  // 1. devices: exactly the expected registry, nothing else.
  const actualIds = db.devices
    .find({}, { _id: 1 })
    .toArray()
    .map((d) => d._id);
  const missing = EXPECTED_DEVICE_IDS.filter((id) => actualIds.indexOf(id) === -1);
  const unexpected = actualIds.filter((id) => EXPECTED_DEVICE_IDS.indexOf(id) === -1);
  if (actualIds.length !== EXPECTED_DEVICE_IDS.length) {
    problems.push(
      "devices: expected exactly " + EXPECTED_DEVICE_IDS.length +
        " entries, found " + actualIds.length,
    );
  }
  if (missing.length) {
    problems.push("devices: missing " + JSON.stringify(missing));
  }
  if (unexpected.length) {
    problems.push("devices: unexpected " + JSON.stringify(unexpected));
  }

  // 2. sensor_readings: the deterministic #70 seed is present and intact, in the
  //    new schema, with BSON Date timestamps. This is a POSITIVE check on the
  //    seeded rows, not a "no other shape allowed" check: until #71 the
  //    simulator legitimately keeps writing old-schema documents into the same
  //    collection, and a normal restart must still validate as complete.
  readings.forEach((expected) => {
    const matches = db.sensor_readings.countDocuments(expected);
    if (matches !== 1) {
      problems.push(
        "sensor_readings: expected exactly one seeded reading " +
          EJSON.stringify(expected) + ", found " + matches,
      );
    }
  });

  // 3. sensor_readings: required indexes exist.
  for (const wanted of REQUIRED_READING_INDEXES) {
    if (!hasRequiredIndex(db.sensor_readings, wanted)) {
      problems.push("sensor_readings: missing required index " + indexKeyString(wanted));
    }
  }

  return problems;
}

function reportAndExit(problems, context) {
  print("❌ " + context);
  problems.forEach((p) => print("   - " + p));
  print(
    "   Refusing to touch persistent data. Fix the state, or reset the volume " +
      "(`docker compose down -v`) to reseed from scratch.",
  );
  quit(1);
}

// ---------------------------------------------------------------------------
// Issue #73: additive alert bootstrap. Runs AFTER the #70 base-state decision
// and never touches `devices` / `sensor_readings`. Same fail-closed contract,
// scoped to the alert schema:
//   * alert schema entirely absent  -> seed `alert_rules` + `alert_events` indexes
//   * complete #73 alert state      -> validate, no reseed, no deletion
//   * partial / inconsistent state  -> print the reason, exit non-zero
// Ordering inside the seed puts the indexes LAST, so a crash mid-seed leaves a
// state that validation rejects on the next run — it can never later look
// "complete" by accident.
// ---------------------------------------------------------------------------

function alertEventsHasIndex(wantedKey) {
  if (db.getCollectionNames().indexOf("alert_events") === -1) {
    return false;
  }
  return hasRequiredIndex(db.alert_events, wantedKey);
}

function alertRuleEquals(expected, actual) {
  const em = expected.match || {};
  const am = actual.match || {};
  return (
    actual.ruleId === expected.ruleId &&
    actual.enabled === expected.enabled &&
    actual.operator === expected.operator &&
    actual.threshold === expected.threshold &&
    actual.clearThreshold === expected.clearThreshold &&
    actual.severity === expected.severity &&
    (am.deviceId || null) === (em.deviceId || null) &&
    (am.deviceKind || null) === (em.deviceKind || null) &&
    am.channel === em.channel
  );
}

// Reasons the persisted alert schema is not a complete, consistent #73 state.
// Empty list == fully initialised.
function alertCompletenessProblems() {
  const problems = [];

  const actualRules = db.alert_rules.find({}).toArray();
  const actualIds = actualRules.map((r) => r._id);
  const expectedIds = EXPECTED_ALERT_RULES.map((r) => r._id);
  const missing = expectedIds.filter((id) => actualIds.indexOf(id) === -1);
  const unexpected = actualIds.filter((id) => expectedIds.indexOf(id) === -1);

  if (actualIds.length !== expectedIds.length) {
    problems.push(
      "alert_rules: expected exactly " + expectedIds.length +
        " rules, found " + actualIds.length,
    );
  }
  if (missing.length) {
    problems.push("alert_rules: missing " + JSON.stringify(missing));
  }
  if (unexpected.length) {
    problems.push("alert_rules: unexpected " + JSON.stringify(unexpected));
  }
  EXPECTED_ALERT_RULES.forEach((expected) => {
    const actual = actualRules.find((r) => r._id === expected._id);
    if (actual && !alertRuleEquals(expected, actual)) {
      problems.push(
        "alert_rules: '" + expected._id + "' config differs from the approved seed",
      );
    }
  });

  for (const wanted of REQUIRED_ALERT_EVENT_INDEXES) {
    if (!alertEventsHasIndex(wanted)) {
      problems.push("alert_events: missing required index " + indexKeyString(wanted));
    }
  }

  const eventsCount =
    db.getCollectionNames().indexOf("alert_events") !== -1
      ? db.alert_events.countDocuments()
      : 0;
  if (eventsCount > 0 && (missing.length || unexpected.length)) {
    problems.push(
      "alert_events: " + eventsCount +
        " event(s) present while the alert_rules bootstrap is incomplete",
    );
  }

  return problems;
}

function seedAlertSchema() {
  db.alert_rules.insertMany(EXPECTED_ALERT_RULES, { ordered: true });
  // Indexes LAST (see the section comment above).
  REQUIRED_ALERT_EVENT_INDEXES.forEach((key) => db.alert_events.createIndex(key));
}

// #94 ordering metadata is additive. Legacy alert documents deliberately stay
// untouched and map to sequence 0; the counter starts at the greatest sequence
// already present, or zero for a legacy/fresh volume.
function alertSequenceBootstrap() {
  const latest = db.alert_events
    .find({ sequence: { $type: "number" } })
    .sort({ sequence: -1 })
    .limit(1)
    .toArray();
  const maxSequence = latest.length
    ? NumberLong(latest[0].sequence.toString())
    : NumberLong("0");
  const current = db.alert_sequences.findOne({ _id: "global" });

  if (!current) {
    db.alert_sequences.insertOne({ _id: "global", value: maxSequence });
    print("✅ alert sequence counter initialised at " + maxSequence);
    return;
  }
  const validCounter = db.alert_sequences.countDocuments({
    _id: "global",
    value: { $gte: NumberLong("0") },
    $or: [{ value: { $type: "int" } }, { value: { $type: "long" } }],
  });
  if (validCounter !== 1) {
    reportAndExit(
      ["alert_sequences: global value must be a nonnegative BSON integer"],
      "alert sequence state is inconsistent",
    );
  }
  if (current.value < maxSequence) {
    db.alert_sequences.updateOne({ _id: "global" }, { $set: { value: maxSequence } });
    print("✅ alert sequence counter advanced to existing maximum " + maxSequence);
  }
}

function alertBootstrap() {
  const rulesCount = db.alert_rules.countDocuments();
  const eventsExist = db.getCollectionNames().indexOf("alert_events") !== -1;
  const eventsCount = eventsExist ? db.alert_events.countDocuments() : 0;
  const indexesPresent = REQUIRED_ALERT_EVENT_INDEXES.filter((k) =>
    alertEventsHasIndex(k),
  ).length;

  const isAlertFresh =
    rulesCount === 0 && !eventsExist && eventsCount === 0 && indexesPresent === 0;

  if (isAlertFresh) {
    print("🌱 alert schema absent — seeding alert_rules and alert_events indexes");
    seedAlertSchema();

    const problems = alertCompletenessProblems();
    if (problems.length) {
      reportAndExit(problems, "alert seed post-condition failed (this should not happen)");
    }

    print(
      "✅ alert schema seeded: " + db.alert_rules.countDocuments() + " rules, " +
        REQUIRED_ALERT_EVENT_INDEXES.length + " alert_events indexes",
    );
    return;
  }

  print(
    "🔎 alert schema present (" + rulesCount + " rules, " + eventsCount +
      " events) — validating completeness, no reseed",
  );
  const problems = alertCompletenessProblems();
  if (problems.length) {
    reportAndExit(problems, "alert bootstrap state is partial or inconsistent");
  }

  print("✅ alert schema is complete and consistent — nothing to do");
}

// Deterministic fresh seed. Ordering matters: readings, then the registry, then
// the indexes LAST — so a crash at any point leaves a state that
// completenessProblems() rejects on the next run (it can never later look
// "complete" by accident).
function seedFresh() {
  db.devices.drop();
  db.sensor_readings.drop();

  db.sensor_readings.insertMany(readings, { ordered: true });
  db.devices.insertMany(devices, { ordered: true });

  db.sensor_readings.createIndex({ deviceId: 1, channel: 1, timestamp: -1 });
  db.sensor_readings.createIndex({ timestamp: -1 });
}

// ---------------------------------------------------------------------------
// Decision
// ---------------------------------------------------------------------------

const devicesCount = db.devices.countDocuments();
const readingsCount = db.sensor_readings.countDocuments();
const isFresh = devicesCount === 0 && readingsCount === 0;

if (isFresh) {
  print("🌱 fresh database — performing deterministic seed");
  seedFresh();

  const problems = completenessProblems();
  if (problems.length) {
    reportAndExit(problems, "seed post-condition failed (this should not happen)");
  }

  print(
    "✅ seeded: " + db.devices.countDocuments() + " devices, " +
      db.sensor_readings.countDocuments() + " readings, required indexes present",
  );
} else {
  print(
    "🔎 existing database (" + devicesCount + " devices, " + readingsCount +
      " readings) — validating completeness, no reseed",
  );
  const problems = completenessProblems();
  if (problems.length) {
    reportAndExit(problems, "existing state is partial or inconsistent");
  }

  print("✅ existing state is complete and consistent — nothing to do");
}

// Issue #73: additive alert bootstrap, as a separate phase after the base-state
// decision above. A pre-#73 but otherwise valid database initialises the alert
// schema here and succeeds; a completed state validates; a partial state exits
// non-zero (reportAndExit).
alertBootstrap();
alertSequenceBootstrap();

quit(0);
