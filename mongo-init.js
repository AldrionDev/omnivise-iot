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

const DB_NAME = "omnivise_iot";

// The registry the seed produces. Existing-state validation requires exactly
// these ids — no more, no fewer.
const EXPECTED_DEVICE_IDS = ["rack-a1", "rack-a2", "ups-1", "pdu-a1", "crac-1"];

// Index key specs that must exist on `sensor_readings` for a state to count as
// initialised.
const REQUIRED_READING_INDEXES = [
  { deviceId: 1, channel: 1, timestamp: -1 },
  { timestamp: -1 },
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

db = db.getSiblingDB(DB_NAME);
print("📦 Database: " + DB_NAME);

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
  const seededReadings = db.sensor_readings.countDocuments({
    deviceId: { $exists: true },
    channel: { $exists: true },
    timestamp: { $type: "date" },
  });
  if (seededReadings < readings.length) {
    problems.push(
      "sensor_readings: expected at least " + readings.length +
        " new-schema readings with a BSON Date timestamp, found " + seededReadings +
        " (the #70 seed is missing or incomplete)",
    );
  }

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
  quit(0);
}

print(
  "🔎 existing database (" + devicesCount + " devices, " + readingsCount +
    " readings) — validating completeness, no reseed",
);
const problems = completenessProblems();
if (problems.length) {
  reportAndExit(problems, "existing state is partial or inconsistent");
}

print("✅ existing state is complete and consistent — nothing to do");
quit(0);
