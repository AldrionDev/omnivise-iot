#!/usr/bin/env bash
# Verifies the additive, fail-closed alert firing uniqueness phase of
# mongo-init.js against a running replica-set MongoDB container.
#
# Usage: MONGO_CONTAINER=omnivise-mongodb tests/mongo-alert-firing-uniqueness.test.sh

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CONTAINER="${MONGO_CONTAINER:-omnivise-mongodb}"
readonly URI="mongodb://localhost:27017/?replicaSet=rs0&directConnection=true"
readonly SCRIPT_IN_CONTAINER="/tmp/mongo-init-uniqueness-test.js"
readonly PREFIX="alert_uniqueness_test_$$"
readonly INDEX_NAME="uniq_firing_rule_device_channel"
DATABASES=()

cleanup() {
  for database in "${DATABASES[@]}"; do
    mongo_eval "db.getSiblingDB('$database').dropDatabase()" >/dev/null || true
  done
  docker exec "$CONTAINER" rm -f "$SCRIPT_IN_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mongo_eval() {
  docker exec "$CONTAINER" mongosh "$URI" --quiet --eval "$1"
}

bootstrap() {
  docker exec -e MONGO_INITDB_DATABASE="$1" "$CONTAINER" \
    mongosh "$URI" --quiet --file "$SCRIPT_IN_CONTAINER"
}

# Sets $database to a freshly bootstrapped, cleanup-registered database.
use_seeded_database() {
  database="${PREFIX}_$1"
  DATABASES+=("$database")
  bootstrap "$database" >/dev/null
}

# Simulates a database bootstrapped before the uniqueness index existed.
drop_unique_index() {
  mongo_eval "db.getSiblingDB('$1').alert_events.dropIndex('$INDEX_NAME')" >/dev/null
}

insert_events() {
  mongo_eval "db.getSiblingDB('$1').alert_events.insertMany($2.map((state) => ({
    ruleId: 'ups-input-voltage-low', deviceId: 'ups-1', channel: 'input_voltage',
    severity: 'critical', state, triggeredValue: 2.0, lastValue: 2.0,
    startedAt: new Date('2026-09-17T12:46:34Z'),
  })))" >/dev/null
}

assert_unique_index() {
  mongo_eval "
    const ix = db.getSiblingDB('$1').alert_events.getIndexes().find((i) => i.name === '$INDEX_NAME');
    if (!ix || ix.unique !== true
        || JSON.stringify(ix.key) !== JSON.stringify({ ruleId: 1, deviceId: 1, channel: 1 })
        || JSON.stringify(ix.partialFilterExpression) !== JSON.stringify({ state: 'firing' })) {
      print('unexpected index: ' + JSON.stringify(ix));
      quit(1);
    }" >/dev/null
}

assert_no_unique_index() {
  mongo_eval "
    if (db.getSiblingDB('$1').alert_events.getIndexes().some((i) => i.name === '$INDEX_NAME')) quit(1);
  " >/dev/null
}

assert_event_count() {
  local actual
  actual="$(mongo_eval "db.getSiblingDB('$1').alert_events.countDocuments()")"
  [ "$actual" = "$2" ] || { echo "expected $2 alert_events in $1, found $actual"; return 1; }
}

docker cp "$ROOT_DIR/mongo-init.js" "$CONTAINER:$SCRIPT_IN_CONTAINER" >/dev/null

# 1. Fresh bootstrap creates the index; a rerun is idempotent.
use_seeded_database fresh
assert_unique_index "$database"
output="$(bootstrap "$database")"
grep -q "alert firing uniqueness index present" <<<"$output"
echo "ok - fresh bootstrap creates the index and reruns idempotently"

# 2. Pre-existing state with resolved history for the key gains the index additively.
use_seeded_database upgrade
drop_unique_index "$database"
insert_events "$database" "['resolved', 'resolved', 'firing']"
output="$(bootstrap "$database")"
grep -q "alert firing uniqueness index created" <<<"$output"
assert_unique_index "$database"
assert_event_count "$database" 3
echo "ok - existing resolved history is preserved and the index is added"

# 3. A pre-existing firing duplicate fails closed and deletes nothing.
use_seeded_database duplicate
drop_unique_index "$database"
insert_events "$database" "['firing', 'firing', 'resolved']"
if output="$(bootstrap "$database")"; then
  echo "expected bootstrap to fail on duplicate firing alerts"
  exit 1
fi
grep -q "duplicate firing alerts prevent the firing uniqueness index" <<<"$output"
grep -q '2 firing events for {"ruleId":"ups-input-voltage-low","deviceId":"ups-1","channel":"input_voltage"}' <<<"$output"
assert_no_unique_index "$database"
assert_event_count "$database" 3
echo "ok - firing duplicates fail the bootstrap without deleting data"

# 4. A same-named index with a different definition fails closed.
use_seeded_database conflicting
drop_unique_index "$database"
mongo_eval "db.getSiblingDB('$database').alert_events.createIndex(
  { ruleId: 1, deviceId: 1, channel: 1 }, { name: '$INDEX_NAME' })" >/dev/null
if output="$(bootstrap "$database")"; then
  echo "expected bootstrap to fail on a conflicting index definition"
  exit 1
fi
grep -q "alert firing uniqueness index is inconsistent" <<<"$output"
echo "ok - a conflicting index definition fails the bootstrap"
