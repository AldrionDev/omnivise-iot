#!/usr/bin/env bash
#
# assert.sh — minimal framework-free assertion helpers for the workflow-core
# test suite. Sourced by .claude/tests/run.sh. Every assertion records a result;
# the runner reports totals and decides the exit status.

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

# run_capture CMD... — run without aborting the suite; capture RC / OUT / ERR.
run_capture() {
  local err_file
  err_file="$(mktemp)"
  set +e
  OUT="$("$@" 2>"$err_file")"
  RC=$?
  set -e
  ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# run_capture_in DIR CMD... — same, executed with CWD = DIR.
run_capture_in() {
  local dir="$1"
  shift
  local err_file
  err_file="$(mktemp)"
  set +e
  OUT="$(cd "$dir" && "$@" 2>"$err_file")"
  RC=$?
  set -e
  ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

assert_ok() {
  local name="$1"
  shift
  run_capture "$@"
  if [ "$RC" -eq 0 ]; then _pass "$name"; else _fail "$name" "expected exit 0, got $RC: ${ERR:-$OUT}"; fi
}

assert_fail() {
  local name="$1"
  shift
  run_capture "$@"
  if [ "$RC" -ne 0 ]; then _pass "$name"; else _fail "$name" "expected non-zero exit, got 0"; fi
}

# assert_fail_code NAME CODE CMD... — command must fail and print CODE on stderr.
assert_fail_code() {
  local name="$1" code="$2"
  shift 2
  run_capture "$@"
  if [ "$RC" -eq 0 ]; then
    _fail "$name" "expected failure with $code, but exit was 0 (stdout: $OUT)"
  elif [[ "$ERR" != *"$code"* ]]; then
    _fail "$name" "expected $code on stderr, got: ${ERR:-<empty>}"
  else
    _pass "$name"
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then _pass "$name"
  else _fail "$name" "expected [$expected], got [$actual]"; fi
}

assert_ne() {
  local name="$1" a="$2" b="$3"
  if [ "$a" != "$b" ]; then _pass "$name"
  else _fail "$name" "expected values to differ, both were [$a]"; fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then _pass "$name"
  else _fail "$name" "expected to contain [$needle], got: $haystack"; fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then _pass "$name"
  else _fail "$name" "expected NOT to contain [$needle], got: $haystack"; fi
}

assert_file_exists() {
  local name="$1" path="$2"
  if [ -e "$path" ]; then _pass "$name"; else _fail "$name" "expected path to exist: $path"; fi
}

assert_file_absent() {
  local name="$1" path="$2"
  if [ ! -e "$path" ]; then _pass "$name"; else _fail "$name" "expected path to be absent: $path"; fi
}

# assert_json NAME JSON — JSON must parse.
assert_json() {
  local name="$1" json="$2"
  if printf '%s' "$json" | jq empty >/dev/null 2>&1; then _pass "$name"
  else _fail "$name" "expected valid JSON, got: $json"; fi
}
