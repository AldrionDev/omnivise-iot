#!/usr/bin/env bash

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()
CURRENT_SUITE="(none)"

suite() {
  CURRENT_SUITE="$1"
  printf '\n== %s ==\n' "$1"
}

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '  ok   %s\n' "$1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("[$CURRENT_SUITE] $1 -- $2")
  printf '  FAIL %s\n       %s\n' "$1" "$2"
}

# OUT/RC/ERR are results read by the sourcing test suites.
# shellcheck disable=SC2034
run_capture() {
  local err_file
  err_file="$(mktemp "$TEST_TMP_ROOT/stderr.XXXXXX")"

  set +e
  OUT="$("$@" 2>"$err_file")"
  RC=$?
  set -e

  ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$name"
  else
    _fail "$name" "expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$name"
  else
    _fail "$name" "expected to contain [$needle], got: $haystack"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    _pass "$name"
  else
    _fail "$name" "expected NOT to contain [$needle], got: $haystack"
  fi
}
