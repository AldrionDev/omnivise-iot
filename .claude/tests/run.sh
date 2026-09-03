#!/usr/bin/env bash
#
# run.sh — deterministic, framework-free test suite for the workflow-core
# scripts under .claude/scripts/.
#
# The suite is entirely offline and non-destructive: every test builds a
# throwaway Git repository under a temporary root and never touches the real
# repository, a remote, or a host service. Real build tools (mvn / npm) are never
# invoked; verification behaviour is exercised with fake executables on PATH.
#
#   bash .claude/tests/run.sh          # run everything
#   bash .claude/tests/run.sh candidate   # run suites whose filename matches

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

export SCRIPTS_DIR="$REPO_ROOT/.claude/scripts"
export CONTRACT_SH="$SCRIPTS_DIR/issue-contract.sh"
export STATE_SH="$SCRIPTS_DIR/workflow-state.sh"
export CANDIDATE_SH="$SCRIPTS_DIR/candidate.sh"
export VERIFY_SH="$SCRIPTS_DIR/verify.sh"
export OMNIVISE_REPO_ROOT="$REPO_ROOT"

for tool in git jq rg sha256sum realpath flock readlink; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'TEST_TOOLING_MISSING: %s is required\n' "$tool" >&2
    exit 1
  }
done

TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/workflow-core-tests.XXXXXX")"
export TEST_TMP_ROOT
cleanup() { rm -rf "$TEST_TMP_ROOT"; }
trap cleanup EXIT

# Keep any ambient project dir out of the fixtures.
unset CLAUDE_PROJECT_DIR 2>/dev/null || true

# shellcheck source=lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/fixtures.sh
. "$TESTS_DIR/lib/fixtures.sh"

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

printf '\nAll workflow-core tests passed.\n'
