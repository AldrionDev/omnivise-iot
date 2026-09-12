#!/usr/bin/env bash

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPOSE_FILES=(-f "$ROOT_DIR/docker-compose.yml" -f "$ROOT_DIR/tests/docker-compose.runtime.yml")
readonly COMPOSE_ARGS=(--env-file /dev/null "${COMPOSE_FILES[@]}")
readonly IMAGE_PREFIX="issue98-runtime-$$"
CURRENT_PROJECT=""

cleanup() {
  if [ -n "$CURRENT_PROJECT" ]; then
    env -u MONGO_INITDB_DATABASE COMPOSE_PROJECT_NAME="$CURRENT_PROJECT" \
      ISSUE98_IMAGE_PREFIX="$IMAGE_PREFIX" \
      docker compose "${COMPOSE_ARGS[@]}" down -v || true
  fi
  docker image rm "$IMAGE_PREFIX-backend:latest" \
    "$IMAGE_PREFIX-sensor-simulator:latest" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_case() {
  local label="$1"
  local database="$2"
  local build_flag="$3"
  local project="issue98-runtime-$label-$$"
  local mongodb="$project-mongodb"
  local seeder="$project-mongo-seed"
  local backend="$project-backend"
  local simulator="$project-sensor-simulator"
  local -a compose_env=(env)

  if [ "$label" = "default" ]; then
    compose_env+=(--unset=MONGO_INITDB_DATABASE)
  else
    compose_env+=(MONGO_INITDB_DATABASE="$database")
  fi
  compose_env+=(COMPOSE_PROJECT_NAME="$project" ISSUE98_IMAGE_PREFIX="$IMAGE_PREFIX")

  CURRENT_PROJECT="$project"
  if [ "$build_flag" = "--build" ]; then
    "${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" \
      build backend sensor-simulator
  fi
  "${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" up -d mongodb

  local mongo_health=""
  for _ in $(seq 1 60); do
    mongo_health="$(docker inspect --format '{{.State.Health.Status}}' "$mongodb")"
    [ "$mongo_health" = "healthy" ] && break
    sleep 2
  done
  [ "$mongo_health" = "healthy" ]

  "${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" \
    up -d mongo-seed backend sensor-simulator

  local backend_health=""
  for _ in $(seq 1 60); do
    backend_health="$(docker inspect --format '{{.State.Health.Status}}' "$backend")"
    [ "$backend_health" = "healthy" ] && break
    sleep 2
  done
  [ "$backend_health" = "healthy" ]

  docker exec "$mongodb" mongosh --quiet --eval "
    const configured = db.getSiblingDB('$database');
    if (configured.devices.countDocuments() !== 5) quit(1);
    if (configured.alert_rules.countDocuments() !== 5) quit(1);
    const sequence = configured.alert_sequences.findOneAndUpdate(
      { _id: 'global' },
      { \$inc: { value: NumberLong('1') } },
      { returnDocument: 'after' },
    );
    if (!sequence || sequence.value.toString() !== '1') quit(1);
    printjson({
      database: configured.getName(),
      devices: configured.devices.countDocuments(),
      alertRules: configured.alert_rules.countDocuments(),
      alertSequence: sequence.value,
    });
  "

  docker exec "$backend" wget -qO- http://localhost:8080/api/devices \
    | node -e "let input=''; process.stdin.on('data', c => input += c); process.stdin.on('end', () => { const count=JSON.parse(input).length; if (count !== 5) process.exit(1); console.log('backend devices: ' + count); });"
  docker exec "$backend" wget -qO- http://localhost:8080/api/alerts/rules \
    | node -e "let input=''; process.stdin.on('data', c => input += c); process.stdin.on('end', () => { const count=JSON.parse(input).length; if (count !== 5) process.exit(1); console.log('backend alert rules: ' + count); });"
  local registry_loaded=false
  for _ in $(seq 1 30); do
    if docker logs "$simulator" 2>&1 | grep -q "Registry loaded: 5 devices"; then
      registry_loaded=true
      break
    fi
    sleep 1
  done
  [ "$registry_loaded" = true ]
  docker logs "$simulator" 2>&1 | grep "Registry loaded: 5 devices"

  local before_snapshot
  before_snapshot="$(docker exec "$mongodb" mongosh --quiet --eval "
    const configured = db.getSiblingDB('$database');
    const seededReadingTimes = [
      ISODate('2026-09-10T08:00:00Z'),
      ISODate('2026-09-10T08:05:00Z'),
    ];
    const seededReadings = configured.sensor_readings
      .find({ timestamp: { \$in: seededReadingTimes } })
      .sort({ deviceId: 1, channel: 1, timestamp: 1, unit: 1, value: 1, _id: 1 })
      .toArray()
      .map(({ _id, ...reading }) => reading);
    if (seededReadings.length !== 40) quit(1);
    print(EJSON.stringify({
      devices: configured.devices.find({}).sort({ _id: 1 }).toArray(),
      alertRules: configured.alert_rules.find({}).sort({ _id: 1 }).toArray(),
      alertSequences: configured.alert_sequences.find({}).sort({ _id: 1 }).toArray(),
      seededReadings,
    }, { relaxed: false }));
  ")"

  docker start -a "$seeder"
  local after_snapshot
  after_snapshot="$(docker exec "$mongodb" mongosh --quiet --eval "
    const configured = db.getSiblingDB('$database');
    const seededReadingTimes = [
      ISODate('2026-09-10T08:00:00Z'),
      ISODate('2026-09-10T08:05:00Z'),
    ];
    const seededReadings = configured.sensor_readings
      .find({ timestamp: { \$in: seededReadingTimes } })
      .sort({ deviceId: 1, channel: 1, timestamp: 1, unit: 1, value: 1, _id: 1 })
      .toArray()
      .map(({ _id, ...reading }) => reading);
    if (seededReadings.length !== 40) quit(1);
    print(EJSON.stringify({
      devices: configured.devices.find({}).sort({ _id: 1 }).toArray(),
      alertRules: configured.alert_rules.find({}).sort({ _id: 1 }).toArray(),
      alertSequences: configured.alert_sequences.find({}).sort({ _id: 1 }).toArray(),
      seededReadings,
    }, { relaxed: false }));
  ")"
  [ "$before_snapshot" = "$after_snapshot" ]
  local print_idempotency_evidence
  print_idempotency_evidence="$(node -e "const state=JSON.parse(process.argv[1]); if (state.alertSequences.length !== 1) process.exit(1); console.log('canonical bootstrap state preserved ' + state.devices.length + ' devices, ' + state.alertRules.length + ' rules, sequence ' + state.alertSequences[0].value.\$numberLong + ', and ' + state.seededReadings.length + ' seeded readings');" "$after_snapshot")"
  printf '%s\n' "$print_idempotency_evidence"

  docker exec "$mongodb" mongosh --quiet --eval "
    db.getSiblingDB('$database').sensor_readings.updateOne(
      {
        deviceId: 'rack-a1',
        channel: 'intake_temp',
        timestamp: ISODate('2026-09-10T08:00:00Z'),
      },
      { \$set: { value: -999 } },
    );
  "
  local mutated_output=""
  if mutated_output="$(docker start -a "$seeder" 2>&1)"; then
    printf 'bootstrap unexpectedly accepted a mutated seeded reading\n' >&2
    return 1
  fi
  grep -q "expected exactly one seeded reading" <<<"$mutated_output"
  printf 'bootstrap rejected a mutated seeded reading\n'

  docker exec "$mongodb" mongosh --quiet --eval "
    const readings = db.getSiblingDB('$database').sensor_readings;
    readings.updateOne(
      {
        deviceId: 'rack-a1',
        channel: 'intake_temp',
        timestamp: ISODate('2026-09-10T08:00:00Z'),
      },
      { \$set: { value: 21.4 } },
    );
    const duplicate = readings.findOne({
      deviceId: 'rack-a1',
      channel: 'intake_temp',
      timestamp: ISODate('2026-09-10T08:00:00Z'),
    });
    delete duplicate._id;
    readings.insertOne(duplicate);
  "
  local duplicated_output=""
  if duplicated_output="$(docker start -a "$seeder" 2>&1)"; then
    printf 'bootstrap unexpectedly accepted a duplicated seeded reading\n' >&2
    return 1
  fi
  grep -q "expected exactly one seeded reading" <<<"$duplicated_output"
  printf 'bootstrap rejected a duplicated seeded reading\n'

  if [ "$database" != "omnivise_iot" ]; then
    docker exec "$mongodb" mongosh --quiet --eval '
      const names = db.getSiblingDB("omnivise_iot").getCollectionNames();
      const applicationCollections = [
        "devices", "sensor_readings", "alert_rules", "alert_events", "alert_sequences",
      ];
      if (names.some(name => applicationCollections.includes(name))) quit(1);
      printjson({ defaultDatabaseApplicationCollections: [] });
    '
  fi

  "${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" down -v
  CURRENT_PROJECT=""
}

run_rejected_selector_case() {
  local label="$1"
  local selector="$2"
  local project="issue98-runtime-rejected-$label-$$"
  local mongodb="$project-mongodb"
  local -a compose_env=(env MONGO_INITDB_DATABASE="$selector")
  compose_env+=(COMPOSE_PROJECT_NAME="$project" ISSUE98_IMAGE_PREFIX="$IMAGE_PREFIX")

  CURRENT_PROJECT="$project"
  "${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" up -d mongodb

  local mongo_ready=false
  for _ in $(seq 1 60); do
    if docker exec "$mongodb" mongosh --quiet --eval \
      'quit(db.adminCommand({ ping: 1 }).ok === 1 ? 0 : 1)' >/dev/null 2>&1; then
      mongo_ready=true
      break
    fi
    sleep 2
  done
  [ "$mongo_ready" = true ]

  docker exec "$mongodb" mongosh --quiet --eval '
    try {
      rs.status();
    } catch (error) {
      rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongodb:27017" }] });
    }
  '
  local primary_ready=false
  for _ in $(seq 1 60); do
    if docker exec "$mongodb" mongosh --quiet --eval \
      'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
      primary_ready=true
      break
    fi
    sleep 1
  done
  [ "$primary_ready" = true ]

  local output=""
  if output="$("${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps \
    mongo-seed 2>&1)"; then
    printf '%s selector unexpectedly succeeded\n' "$label" >&2
    return 1
  fi
  printf '%s\n' "$output"
  grep -q "MONGO_INITDB_DATABASE must select an application database" <<<"$output"

  local component_output=""
  local component
  for component in backend sensor-simulator; do
    if component_output="$("${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" run \
      --rm --no-deps "$component" 2>&1)"; then
      printf '%s accepted a %s selector\n' "$component" "$label" >&2
      return 1
    fi
    printf '%s\n' "$component_output"
    grep -q "MONGO_DATABASE must select an application database" <<<"$component_output"
    printf '%s rejected the %s selector before startup\n' "$component" "$label"
  done

  docker exec "$mongodb" mongosh --quiet --eval '
    const applicationCollections = [
      "devices", "sensor_readings", "alert_rules", "alert_events", "alert_sequences",
    ];
    const leaks = db.adminCommand({ listDatabases: 1 }).databases.flatMap(database => {
      const names = db.getSiblingDB(database.name).getCollectionNames();
      return names.filter(name => applicationCollections.includes(name))
        .map(name => database.name + "." + name);
    });
    if (leaks.length) {
      printjson({ unexpectedApplicationCollections: leaks });
      quit(1);
    }
    print("selector rejected before application bootstrap writes");
  '

  "${compose_env[@]}" docker compose "${COMPOSE_ARGS[@]}" down -v
  CURRENT_PROJECT=""
}

run_case default omnivise_iot --build
run_rejected_selector_case empty ""
run_rejected_selector_case whitespace "   "
run_case alternate omnivise_iot_test --no-build
