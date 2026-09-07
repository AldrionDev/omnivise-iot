#!/bin/sh
# MongoDB PRIMARY readiness gate for the backend and simulator init containers.
#
# Contract:
#   - read-only: the only command issued is db.hello(); the script never calls
#     rs.initiate / replSetInitiate / rs.reconfig / rs.add / rs.remove;
#   - no writes: it never performs any insert / update / replace / delete / drop
#     / createCollection or any other mutating operation;
#   - bounded: the wait loop is capped by WAIT_MAX_ATTEMPTS and then exits
#     non-zero; it is never an infinite wait;
#   - replica-set bootstrap and reconfiguration belong solely to the #36
#     bootstrap Job, not to this gate.
#
# The script only observes whether the target reports a writable PRIMARY and
# connects exclusively through cluster-internal networking.

set -eu

if [ -z "${MONGODB_WAIT_HOST:-}" ]; then
  echo "error: MONGODB_WAIT_HOST is required and must be non-empty" >&2
  exit 1
fi

WAIT_MAX_ATTEMPTS="${WAIT_MAX_ATTEMPTS:-60}"
WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-5}"

attempt=1
while [ "$attempt" -le "$WAIT_MAX_ATTEMPTS" ]; do
  if mongosh --quiet --host "$MONGODB_WAIT_HOST" --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
    echo "MongoDB at ${MONGODB_WAIT_HOST} is a writable PRIMARY"
    exit 0
  fi
  echo "waiting for MongoDB PRIMARY at ${MONGODB_WAIT_HOST} (attempt ${attempt}/${WAIT_MAX_ATTEMPTS})"
  sleep "$WAIT_SLEEP_SECONDS"
  attempt=$((attempt + 1))
done

echo "error: MongoDB did not report a writable PRIMARY within ${WAIT_MAX_ATTEMPTS} attempts" >&2
exit 1
