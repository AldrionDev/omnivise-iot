#!/bin/sh
# MongoDB single-node replica-set bootstrap.
#
# Contract:
#   - one-time: runs to completion once and performs no continuous
#     reconciliation of replica-set configuration;
#   - idempotent: an already correctly configured replica set is treated as
#     success with no mutation;
#   - bounded: every wait loop is capped by BOOTSTRAP_MAX_ATTEMPTS;
#   - fail-closed: an unexpected or conflicting existing replica-set topology
#     causes a non-zero exit instead of an automatic reconfiguration.
#
# The script tolerates the mongod pod not existing yet and the pod being
# Kubernetes NotReady. It connects only through cluster-internal networking.

set -eu

if [ -z "${MONGODB_MEMBER_HOST:-}" ]; then
  echo "error: MONGODB_MEMBER_HOST is required and must be non-empty" >&2
  exit 1
fi

if [ -z "${MONGODB_REPLICA_SET:-}" ]; then
  echo "error: MONGODB_REPLICA_SET is required and must be non-empty" >&2
  exit 1
fi

BOOTSTRAP_MAX_ATTEMPTS="${BOOTSTRAP_MAX_ATTEMPTS:-60}"
BOOTSTRAP_SLEEP_SECONDS="${BOOTSTRAP_SLEEP_SECONDS:-5}"

mongo_eval() {
  mongosh --quiet --host "$MONGODB_MEMBER_HOST" --eval "$1"
}

# 1. Bounded wait for the mongod process to answer a non-mutating ping.
#    Tolerates connection failure (pod absent) and a NotReady pod.
attempt=1
while [ "$attempt" -le "$BOOTSTRAP_MAX_ATTEMPTS" ]; do
  if mongo_eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1; then
    break
  fi
  echo "waiting for mongod (attempt ${attempt}/${BOOTSTRAP_MAX_ATTEMPTS})"
  sleep "$BOOTSTRAP_SLEEP_SECONDS"
  attempt=$((attempt + 1))
done
if [ "$attempt" -gt "$BOOTSTRAP_MAX_ATTEMPTS" ]; then
  echo "error: mongod did not become reachable within ${BOOTSTRAP_MAX_ATTEMPTS} attempts" >&2
  exit 1
fi

# 2. Inspect the current replica-set state without mutating anything.
if ! STATE="$(mongosh --quiet --host "$MONGODB_MEMBER_HOST" --eval '
try {
var status = rs.status();
if (status.ok === 1) {
print("INITIALIZED");
} else {
print("ERROR");
quit(1);
}
} catch (err) {
if (err.code === 94 || err.codeName === "NotYetInitialized") {
print("UNINITIALIZED");
} else {
print("ERROR: " + err.message);
quit(1);
}
}
')"; then
  echo "error: failed to inspect replica-set state: ${STATE:-<no output>}" >&2
  exit 1
fi

# 3. Act on the observed state.
case "$STATE" in
UNINITIALIZED)
  echo "replica set ${MONGODB_REPLICA_SET} is not initialized; initializing a single member"
  if ! mongosh --quiet --host "$MONGODB_MEMBER_HOST" --eval '
var r = rs.initiate({ _id: "'"$MONGODB_REPLICA_SET"'", members: [{ _id: 0, host: "'"$MONGODB_MEMBER_HOST"'" }] });
if (r.ok !== 1) {
print("initiate failed: " + tojson(r));
quit(1);
}
'; then
    echo "error: rs.initiate failed for ${MONGODB_REPLICA_SET}" >&2
    exit 1
  fi
  echo "replica set ${MONGODB_REPLICA_SET} initialized"
  ;;
INITIALIZED)
  if mongosh --quiet --host "$MONGODB_MEMBER_HOST" --eval '
var conf = rs.conf();
if (conf._id === "'"$MONGODB_REPLICA_SET"'" && conf.members.length === 1 && conf.members[0].host === "'"$MONGODB_MEMBER_HOST"'") {
print("OK");
quit(0);
}
print("CONFLICT: " + tojson(conf));
quit(1);
'; then
    echo "replica set already correctly configured; no mutation"
  else
    echo "error: existing replica-set configuration conflicts with the expected single-member topology (${MONGODB_REPLICA_SET} / ${MONGODB_MEMBER_HOST}); failing closed without reconfiguration" >&2
    exit 1
  fi
  ;;
*)
  echo "error: could not determine replica-set state (got: ${STATE:-<empty>}); failing closed" >&2
  exit 1
  ;;
esac

# 4. Bounded wait for the single member to become writable PRIMARY.
attempt=1
while [ "$attempt" -le "$BOOTSTRAP_MAX_ATTEMPTS" ]; do
  if mongo_eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
    break
  fi
  echo "waiting for PRIMARY (attempt ${attempt}/${BOOTSTRAP_MAX_ATTEMPTS})"
  sleep "$BOOTSTRAP_SLEEP_SECONDS"
  attempt=$((attempt + 1))
done
if [ "$attempt" -gt "$BOOTSTRAP_MAX_ATTEMPTS" ]; then
  echo "error: replica-set member did not reach PRIMARY within ${BOOTSTRAP_MAX_ATTEMPTS} attempts" >&2
  exit 1
fi

echo "bootstrap complete: ${MONGODB_REPLICA_SET} has a writable PRIMARY at ${MONGODB_MEMBER_HOST}"
exit 0
