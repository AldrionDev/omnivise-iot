#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

export AWS_DEMO_SH="$REPO_ROOT/scripts/aws-demo.sh"

for tool in bash jq mktemp chmod stat realpath flock setsid ps; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'TEST_TOOLING_MISSING: %s is required\n' "$tool" >&2
    exit 1
  }
done

TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aws-demo-tests.XXXXXX")"
export TEST_TMP_ROOT

# Tests must never resolve the real sibling local-jenkins-platform checkout or
# its running container. Individual tests override these explicitly.
export OMNIVISE_JENKINS_PLATFORM_DIR="$TEST_TMP_ROOT/no-default-platform"
export OMNIVISE_JENKINS_CONTAINER="aws-demo-test-no-such-container"

cleanup() {
  rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

# shellcheck source-path=SCRIPTDIR source=lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

filter="${1:-}"

shopt -s nullglob
suites=("$TESTS_DIR"/*_test.sh)
shopt -u nullglob

if [ "${#suites[@]}" -eq 0 ]; then
  printf 'TEST_SUITE_EMPTY: no *_test.sh files in %s\n' "$TESTS_DIR" >&2
  exit 1
fi

for suite_file in "${suites[@]}"; do
  if [ -n "$filter" ] && [[ "$(basename "$suite_file")" != *"$filter"* ]]; then
    continue
  fi

  # shellcheck disable=SC1090
  . "$suite_file"
done

printf '\n-- summary --\n'
printf '  run:    %d\n' "$TESTS_RUN"
printf '  passed: %d\n' "$TESTS_PASSED"
printf '  failed: %d\n' "$TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
  printf '\nFailures:\n'
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure"
  done
  exit 1
fi

printf '\nAll aws-demo tests passed.\n'
