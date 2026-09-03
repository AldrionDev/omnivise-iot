#!/usr/bin/env bash
#
# verify.sh — deterministic repository verification with a machine-readable
# Verification Record (objective metadata only; no raw command output).
#
#   verify.sh --mode worktree|staged \
#       [--allowed P ...] [--protected P ...] [--contract-file ISSUE_BODY.md] \
#       [--assertions F] [--reviewed-manifest F] \
#       [--run-id ID] [--issue-number N] [--base-branch B] [--base-commit C] \
#       [--record OUT] [--repo-root DIR]
#
# Safety properties:
#   * candidate_scope is the first hard gate: a scope violation is
#     FAIL_IMPLEMENTATION / CANDIDATE_SCOPE_VIOLATION and stops the suite.
#   * every build/test command is bracketed by a COMPLETE candidate fingerprint;
#     a mutation is FAIL_WORKTREE_MUTATION / VERIFICATION_MUTATED_CANDIDATE and
#     stops the suite. Nothing is ever reset/reverted/cleaned/stashed/staged.
#   * command output is captured to a private 0600 temp file OUTSIDE the repo,
#     used only for byte-count / SHA-256 / test-count, then deleted.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

require_cmd jq VERIFY_TOOLING_MISSING
require_cmd git VERIFY_TOOLING_MISSING
require_cmd sha256sum VERIFY_TOOLING_MISSING

CANDIDATE_SH="${CANDIDATE_SH:-$HERE/candidate.sh}"
ISSUE_CONTRACT_SH="${ISSUE_CONTRACT_SH:-$HERE/issue-contract.sh}"

MODE="worktree"
REPO_DIR="$PWD"
ASSERTIONS_FILE=""
REVIEWED_MANIFEST=""
RUN_ID=""
ISSUE_NUMBER=""
RECORD_OUT=""
ALLOWED=()
PROTECTED=()
CONTRACT_FILE=""
BASE_BRANCH=""
BASE_COMMIT=""

REPO_ROOT=""
CHECKS='[]'
STOPPED_EARLY=false
STOPPED_REASON=null
SUITE_RESULT="PASS"

# Private transient command-output capture file. Removed on every trap-reachable
# exit (EXIT/INT/TERM/HUP). Only ever holds an mktemp result under $TMPDIR, so no
# unrelated file is ever touched. A SIGKILL residue is an accepted limitation.
VERIFY_CAPTURE=""
cleanup_capture() {
  [ -n "$VERIFY_CAPTURE" ] && rm -f -- "$VERIFY_CAPTURE" 2>/dev/null
  VERIFY_CAPTURE=""
}
trap cleanup_capture EXIT INT TERM HUP

# Conservative, explicit tool/network failure phrases only — never a bare "network".
readonly ENV_RE='ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ETIMEDOUT|getaddrinfo|network error|[Nn]etwork is unreachable|request to https?://[^ ]+ failed|Could not resolve dependencies|Could not transfer artifact|UnknownHostException|Connection timed out|in offline mode|Cannot connect to the Docker daemon|permission denied while trying to connect to the Docker daemon'

# --------------------------------------------------------------------------

cand() { bash "$CANDIDATE_SH" --repo-root "$REPO_ROOT" "$@"; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)              MODE="${2:-}"; shift 2 ;;
      --repo-root)         REPO_DIR="${2:-}"; shift 2 ;;
      --allowed)           ALLOWED+=("${2:-}"); shift 2 ;;
      --protected)         PROTECTED+=("${2:-}"); shift 2 ;;
      --contract-file)     CONTRACT_FILE="${2:-}"; shift 2 ;;
      --assertions)        ASSERTIONS_FILE="${2:-}"; shift 2 ;;
      --reviewed-manifest) REVIEWED_MANIFEST="${2:-}"; shift 2 ;;
      --run-id)            RUN_ID="${2:-}"; shift 2 ;;
      --issue-number)      ISSUE_NUMBER="${2:-}"; shift 2 ;;
      --base-branch)       BASE_BRANCH="${2:-}"; shift 2 ;;
      --base-commit)       BASE_COMMIT="${2:-}"; shift 2 ;;
      --record)            RECORD_OUT="${2:-}"; shift 2 ;;
      -h|--help)           usage ;;
      *) fail VERIFY_USAGE "unknown argument: $1" ;;
    esac
  done
  case "$MODE" in worktree|staged) : ;; *) fail VERIFY_USAGE "mode must be worktree or staged" ;; esac

  # --contract-file is the Markdown issue body. It is deterministically validated
  # and its path contract is extracted via issue-contract.sh; only JSON ever
  # reaches jq here, and a contract problem is reported as VERIFY_CONTRACT_INVALID
  # rather than degrading into VERIFY_USAGE.
  if [ -n "$CONTRACT_FILE" ]; then
    [ -f "$CONTRACT_FILE" ] || fail VERIFY_CONTRACT_INVALID "contract file not found: $CONTRACT_FILE"
    [ -x "$ISSUE_CONTRACT_SH" ] || [ -f "$ISSUE_CONTRACT_SH" ] ||
      fail VERIFY_CONTRACT_INVALID "issue-contract.sh helper not found: $ISSUE_CONTRACT_SH"

    local ic_err
    ic_err="$(bash "$ISSUE_CONTRACT_SH" validate "$CONTRACT_FILE" 2>&1 >/dev/null)" ||
      fail VERIFY_CONTRACT_INVALID "issue contract did not validate (${ic_err:-no detail})"

    local paths_json
    paths_json="$(bash "$ISSUE_CONTRACT_SH" paths "$CONTRACT_FILE" 2>/dev/null)" ||
      fail VERIFY_CONTRACT_INVALID "could not extract the path contract from $CONTRACT_FILE"
    printf '%s' "$paths_json" | jq -e 'type == "object" and (has("allowed") and has("protected"))' >/dev/null 2>&1 ||
      fail VERIFY_CONTRACT_INVALID "path-contract output is not the expected JSON object"

    mapfile -t ALLOWED   < <(printf '%s' "$paths_json" | jq -r '.allowed[]?')
    mapfile -t PROTECTED < <(printf '%s' "$paths_json" | jq -r '.protected[]?')
    [ "${#ALLOWED[@]}" -gt 0 ] ||
      fail VERIFY_CONTRACT_INVALID "the issue contract declares no Allowed Changed Paths"
    [ "${#PROTECTED[@]}" -gt 0 ] ||
      fail VERIFY_CONTRACT_INVALID "the issue contract declares no Protected Paths"
  fi

  [ "${#ALLOWED[@]}" -gt 0 ]   || fail VERIFY_USAGE "at least one --allowed entry (or --contract-file) is required"
  [ "${#PROTECTED[@]}" -gt 0 ] || fail VERIFY_USAGE "at least one --protected entry (or --contract-file) is required"
  if [ -n "$ISSUE_NUMBER" ]; then
    case "$ISSUE_NUMBER" in *[!0-9]*) fail VERIFY_USAGE "issue number must be an integer" ;; esac
  fi

  # Staged mode must prove the staged candidate equals the reviewed candidate:
  # --reviewed-manifest is mandatory and is checked before any verification runs.
  if [ "$MODE" = staged ]; then
    [ -n "$REVIEWED_MANIFEST" ] ||
      fail VERIFY_USAGE "staged mode requires --reviewed-manifest FILE"
    [ -f "$REVIEWED_MANIFEST" ] ||
      fail VERIFY_USAGE "reviewed manifest not found: $REVIEWED_MANIFEST"
  fi
}

# --------------------------------------------------------------------------
# Record assembly
# --------------------------------------------------------------------------

add_check() {
  # add_check JSON_OBJECT
  CHECKS="$(jq -c --argjson c "$1" '. + [$c]' <<<"$CHECKS")"
}

mark_not_run() {
  # mark_not_run ID...
  local id
  for id in "$@"; do
    add_check "$(jq -cn --arg id "$id" '{id:$id, kind:"skipped", classification:"NOT_RUN"}')"
  done
}

readonly REMAINING_IDS='tracked_whitespace untracked_whitespace docker_compose_config
frontend_install frontend_lint frontend_test frontend_build
simulator_test simulator_package backend_test backend_package'

has_check() {
  jq -e --arg id "$1" 'any(.[]; .id == $id)' <<<"$CHECKS" >/dev/null 2>&1
}

# cand_list_json — capture `candidate.sh list` once and validate it independently
# (exit status, non-empty, JSON parses, JSON type is array). Prints the array on
# success (status 0); prints nothing and returns non-zero when candidate
# enumeration cannot be established. It never emits a fallback like "[] []".
cand_list_json() {
  local out rc
  out="$(cand list 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# finalize_stop — mark any canonical check not yet recorded as NOT_RUN, emit the
# record and exit non-zero. Used whenever the suite stops early mid-run.
finalize_stop() {
  local id
  if [ "$MODE" = staged ]; then
    has_check staged_match || mark_not_run staged_match
  fi
  for id in $REMAINING_IDS; do
    has_check "$id" || mark_not_run "$id"
  done
  emit_record
  exit 1
}

update_suite_result() {
  # a check result that is neither PASS nor NOT_APPLICABLE fails the suite
  case "$1" in
    PASS|NOT_APPLICABLE) : ;;
    *) SUITE_RESULT="FAIL" ;;
  esac
}

# --------------------------------------------------------------------------
# Command execution with mutation guard
# --------------------------------------------------------------------------

# run_guarded_command ID CMD...
# Returns 0 to continue, 1 to stop the suite.
run_guarded_command() {
  local id="$1"; shift
  local -a cmd=("$@")
  local tool="${cmd[0]}"

  if ! command -v "$tool" >/dev/null 2>&1; then
    add_check "$(jq -cn --arg id "$id" --argjson cmd "$(printf '%s\n' "${cmd[@]}" | jq -R . | jq -sc .)" \
      '{id:$id, kind:"command", command:$cmd, cwd:"repo-root", exit_code:null,
        classification:"TOOL_UNAVAILABLE", failure_kind:null}')"
    update_suite_result TOOL_UNAVAILABLE
    return 0
  fi

  local before after before_fp after_fp
  before="$(cand manifest 2>/dev/null)" || { indeterminate_stop "$id" "${cmd[@]}"; return 1; }
  before_fp="$(jq -r '.fingerprint' <<<"$before")"

  local old_umask; old_umask="$(umask)"; umask 077
  local out; out="$(mktemp "${TMPDIR:-/tmp}/verify-out.XXXXXX")"
  VERIFY_CAPTURE="$out"
  chmod 600 "$out" 2>/dev/null || true
  umask "$old_umask"

  local rc
  ( cd "$REPO_ROOT" && "${cmd[@]}" ) >"$out" 2>&1
  rc=$?
  cat "$out" >&2 || true      # transient: shown to the maintainer, never persisted

  after="$(cand manifest 2>/dev/null)" || { rm -f -- "$out"; VERIFY_CAPTURE=""; indeterminate_stop "$id" "${cmd[@]}"; return 1; }
  after_fp="$(jq -r '.fingerprint' <<<"$after")"

  local bytes sha counts env_hit=0
  bytes="$(wc -c <"$out" | tr -d ' ')"
  sha="$(sha256sum <"$out" | awk '{print $1}')"
  counts="$(parse_test_counts "$out")"
  grep -Eq "$ENV_RE" "$out" 2>/dev/null && env_hit=1
  rm -f -- "$out"
  VERIFY_CAPTURE=""

  local cmd_json
  cmd_json="$(printf '%s\n' "${cmd[@]}" | jq -R . | jq -sc .)"

  if [ "$before_fp" != "$after_fp" ]; then
    local changed
    changed="$(jq -cn --argjson a "$(jq -c '.entries' <<<"$before")" --argjson b "$(jq -c '.entries' <<<"$after")" '
      (reduce $a[] as $e ({}; .[$e.path] = {c:$e.change_type,m:$e.mode,t:$e.type,i:$e.content_id,r:$e.rename_from})) as $am
      | (reduce $b[] as $e ({}; .[$e.path] = {c:$e.change_type,m:$e.mode,t:$e.type,i:$e.content_id,r:$e.rename_from})) as $bm
      | ([($am|keys[]),($bm|keys[])] | unique) as $keys
      | [ $keys[] | select( ($am[.]//null) != ($bm[.]//null) ) ]')"
    add_check "$(jq -cn --arg id "$id" --argjson cmd "$cmd_json" --argjson rc "$rc" \
      --argjson bytes "$bytes" --arg sha "$sha" --argjson counts "$counts" \
      --arg bfp "$before_fp" --arg afp "$after_fp" --argjson changed "$changed" \
      '{id:$id, kind:"command", command:$cmd, cwd:"repo-root", exit_code:$rc,
        classification:"FAIL_WORKTREE_MUTATION", failure_kind:"VERIFICATION_MUTATED_CANDIDATE",
        test_counts:$counts, output_bytes:$bytes, output_sha256:$sha,
        fingerprint_before:$bfp, fingerprint_after:$afp,
        mutation:{changed_paths:$changed, failure_kind:"VERIFICATION_MUTATED_CANDIDATE"}}')"
    update_suite_result FAIL_WORKTREE_MUTATION
    STOPPED_EARLY=true
    STOPPED_REASON='"VERIFICATION_MUTATED_CANDIDATE"'
    return 1
  fi

  local cls="PASS"
  if [ "$rc" -eq 0 ]; then
    cls="PASS"
  elif [ "$rc" -eq 127 ]; then
    cls="TOOL_UNAVAILABLE"
  elif [ "$env_hit" -eq 1 ]; then
    cls="FAIL_ENVIRONMENT"
  else
    cls="FAIL_IMPLEMENTATION"
  fi
  add_check "$(jq -cn --arg id "$id" --argjson cmd "$cmd_json" --argjson rc "$rc" \
    --argjson bytes "$bytes" --arg sha "$sha" --argjson counts "$counts" \
    --arg bfp "$before_fp" --arg afp "$after_fp" --arg cls "$cls" \
    '{id:$id, kind:"command", command:$cmd, cwd:"repo-root", exit_code:$rc,
      classification:$cls, failure_kind:null, test_counts:$counts,
      output_bytes:$bytes, output_sha256:$sha,
      fingerprint_before:$bfp, fingerprint_after:$afp}')"
  update_suite_result "$cls"
  return 0
}

indeterminate_stop() {
  local id="$1"; shift
  local cmd_json; cmd_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  add_check "$(jq -cn --arg id "$id" --argjson cmd "$cmd_json" \
    '{id:$id, kind:"command", command:$cmd, cwd:"repo-root", exit_code:null,
      classification:"INDETERMINATE", failure_kind:null}')"
  update_suite_result INDETERMINATE
  STOPPED_EARLY=true
  STOPPED_REASON='"INDETERMINATE"'
}

parse_test_counts() {
  local f="$1" line
  line="$(grep -E 'Tests run: [0-9]+' "$f" 2>/dev/null | tail -1 || true)"
  if [ -n "$line" ]; then
    local t fa er sk
    t="$(sed -nE 's/.*Tests run: ([0-9]+).*/\1/p' <<<"$line")"
    fa="$(sed -nE 's/.*Failures: ([0-9]+).*/\1/p' <<<"$line")"
    er="$(sed -nE 's/.*Errors: ([0-9]+).*/\1/p' <<<"$line")"
    sk="$(sed -nE 's/.*Skipped: ([0-9]+).*/\1/p' <<<"$line")"
    jq -cn --argjson t "${t:-0}" --argjson f "${fa:-0}" --argjson e "${er:-0}" --argjson s "${sk:-0}" \
      '{tests:$t, failures:$f, errors:$e, skipped:$s}'
    return 0
  fi
  printf 'null'
}

# --------------------------------------------------------------------------
# Builtin checks
# --------------------------------------------------------------------------

check_candidate_scope() {
  local out rc e
  local -a a=()
  for e in "${ALLOWED[@]}"; do a+=(--allowed "$e"); done
  for e in "${PROTECTED[@]}"; do a+=(--protected "$e"); done
  [ "$MODE" = staged ] && a+=(--staged)
  out="$(cand scope "${a[@]}" 2>/dev/null)"; rc=$?

  # A well-formed PASS: {"result":"PASS","violations":[]}
  if [ "$rc" -eq 0 ] && \
     jq -e 'type=="object" and .result=="PASS" and (.violations|type=="array")' <<<"$out" >/dev/null 2>&1; then
    add_check "$(jq -cn '{id:"candidate_scope", kind:"builtin", classification:"PASS", failure_kind:null}')"
    update_suite_result PASS
    return 0
  fi

  # A well-formed FAIL with a non-empty violations array.
  if jq -e 'type=="object" and .result=="FAIL" and (.violations|type=="array") and (.violations|length>0)' \
       <<<"$out" >/dev/null 2>&1; then
    local violations; violations="$(jq -c '.violations' <<<"$out")"
    add_check "$(jq -cn --argjson v "$violations" \
      '{id:"candidate_scope", kind:"builtin", classification:"FAIL_IMPLEMENTATION",
        failure_kind:"CANDIDATE_SCOPE_VIOLATION", scope_violations:$v}')"
    update_suite_result FAIL_IMPLEMENTATION
    STOPPED_EARLY=true
    STOPPED_REASON='"CANDIDATE_SCOPE_VIOLATION"'
    return 1
  fi

  # Anything else — exit non-zero, empty output, malformed JSON, missing fields —
  # means candidate scope could not be evaluated. Fail closed as INDETERMINATE;
  # never silently treat this as PASS or an empty check list.
  add_check "$(jq -cn --argjson rc "$rc" \
    '{id:"candidate_scope", kind:"builtin", classification:"INDETERMINATE",
      failure_kind:"SCOPE_EVALUATION_FAILED", exit_code:$rc,
      reason:"candidate scope helper produced no usable result"}')"
  update_suite_result INDETERMINATE
  STOPPED_EARLY=true
  STOPPED_REASON='"SCOPE_EVALUATION_FAILED"'
  return 1
}

check_staged_match() {
  local out rc
  out="$(cand staged-compare --reviewed-manifest "$REVIEWED_MANIFEST" 2>/dev/null)"; rc=$?
  if ! jq -e 'type=="object" and has("ok") and has("staged_matches_reviewed")' <<<"$out" >/dev/null 2>&1; then
    add_check "$(jq -cn --argjson rc "$rc" \
      '{id:"staged_match", kind:"builtin", classification:"INDETERMINATE",
        failure_kind:"STAGED_COMPARE_EVALUATION_FAILED", exit_code:$rc,
        reason:"staged-compare produced no usable result"}')"
    update_suite_result INDETERMINATE
    STOPPED_EARLY=true
    STOPPED_REASON='"STAGED_COMPARE_EVALUATION_FAILED"'
    return 1
  fi
  local ok; ok="$(jq -r '.ok' <<<"$out")"
  if [ "$ok" = true ]; then
    add_check "$(jq -cn --argjson ev "$out" \
      '{id:"staged_match", kind:"builtin", classification:"PASS", failure_kind:null, staged_evidence:$ev}')"
    update_suite_result PASS
    return 0
  fi
  add_check "$(jq -cn --argjson ev "$out" \
    '{id:"staged_match", kind:"builtin", classification:"FAIL_IMPLEMENTATION",
      failure_kind:"STAGED_CANDIDATE_MISMATCH", staged_evidence:$ev}')"
  update_suite_result FAIL_IMPLEMENTATION
  STOPPED_EARLY=true
  STOPPED_REASON='"STAGED_CANDIDATE_MISMATCH"'
  return 1
}

check_tracked_whitespace() {
  local rc
  if [ "$MODE" = staged ]; then
    ( cd "$REPO_ROOT" && git diff --cached --check ) >/dev/null 2>&1 && rc=0 || rc=$?
  else
    ( cd "$REPO_ROOT" && git diff --check ) >/dev/null 2>&1 && rc=0 || rc=$?
  fi
  local cls; [ "$rc" -eq 0 ] && cls=PASS || cls=FAIL_IMPLEMENTATION
  add_check "$(jq -cn --arg cls "$cls" '{id:"tracked_whitespace", kind:"builtin", classification:$cls, failure_kind:null}')"
  update_suite_result "$cls"
}

check_untracked_whitespace() {
  # Fail closed: establish candidate enumeration before iterating. A producer
  # failure must not be seen as "zero untracked files -> PASS".
  local list
  if ! list="$(cand_list_json)"; then
    add_check "$(jq -cn \
      '{id:"untracked_whitespace", kind:"builtin", classification:"INDETERMINATE",
        failure_kind:"CANDIDATE_ENUMERATION_FAILED",
        reason:"candidate.sh list produced no usable result"}')"
    update_suite_result INDETERMINATE
    STOPPED_EARLY=true
    STOPPED_REASON='"CANDIDATE_ENUMERATION_FAILED"'
    return 1
  fi

  local bad=0 b64 f abs out
  # Newline-safe transport: `@base64` emits no newline, so line reading works
  # even when a candidate filename itself contains a newline.
  while IFS= read -r b64; do
    [ -n "$b64" ] || continue
    f="$(printf '%s' "$b64" | base64 -d)"
    [ -n "$f" ] || continue
    abs="$REPO_ROOT/$f"
    [ -f "$abs" ] || continue
    grep -Iq . "$abs" 2>/dev/null || continue   # skip binary
    # `git diff --no-index --check` exits non-zero just because the files differ;
    # a real whitespace problem is what prints diagnostics on stdout.
    out="$( ( cd "$REPO_ROOT" && git diff --no-index --check -- /dev/null "$f" ) 2>&1 || true )"
    [ -n "$out" ] && bad=1
  done < <(jq -r '.[] | select(.tracked==false and .change_type=="added") | (.path | @base64)' <<<"$list")
  local cls; [ "$bad" -eq 0 ] && cls=PASS || cls=FAIL_IMPLEMENTATION
  add_check "$(jq -cn --arg cls "$cls" '{id:"untracked_whitespace", kind:"builtin", classification:$cls, failure_kind:null}')"
  update_suite_result "$cls"
  return 0
}

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

# assertion_abs PATH — resolve PATH's FULL target inside the repository (final
# symlink component included). Prints the canonical absolute path and returns 0
# when it is inside the worktree and not inside .git / the workflow-state
# metadata directory; returns non-zero otherwise. Never exits.
assertion_abs() {
  local rel="$1" abs gitdir
  abs="$(path_within_repo "$REPO_ROOT" "$rel")" || return 1
  gitdir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || printf '')"
  case "$abs" in
    "$REPO_ROOT"/.git|"$REPO_ROOT"/.git/*) return 1 ;;
  esac
  if [ -n "$gitdir" ]; then
    case "$abs" in
      "$gitdir"|"$gitdir"/*) return 1 ;;
    esac
  fi
  printf '%s' "$abs"
  return 0
}

validate_assertions_file() {
  local f="$1"
  jq -e 'type == "array"' "$f" >/dev/null 2>&1 || fail ASSERTION_INPUT_INVALID "assertions file is not a JSON array"
  local n i op path
  n="$(jq 'length' "$f")"
  for ((i = 0; i < n; i++)); do
    jq -e --argjson i "$i" '.[$i] | has("id") and has("op") and has("path")' "$f" >/dev/null 2>&1 ||
      fail ASSERTION_INPUT_INVALID "assertion $i is missing id/op/path"
    op="$(jq -r --argjson i "$i" '.[$i].op' "$f")"
    case "$op" in
      assert_match|assert_no_match|file_exists|file_not_exists) : ;;
      *) fail ASSERTION_UNSUPPORTED_OP "unsupported assertion op: $op" ;;
    esac
    path="$(jq -r --argjson i "$i" '.[$i].path' "$f")"
    validate_rel_path "$path" ASSERTION_PATH_INVALID
    assertion_abs "$path" >/dev/null ||
      fail ASSERTION_PATH_INVALID "assertion path escapes the worktree or targets .git/state: $path"
    if [ "$op" = assert_match ] || [ "$op" = assert_no_match ]; then
      jq -e --argjson i "$i" '.[$i] | has("pattern")' "$f" >/dev/null 2>&1 ||
        fail ASSERTION_INPUT_INVALID "assertion $i ($op) requires a pattern"
    fi
  done
}

run_assertions() {
  local f="$1" n i id op path pattern abs cls rc
  n="$(jq 'length' "$f")"
  for ((i = 0; i < n; i++)); do
    id="$(jq -r --argjson i "$i" '.[$i].id' "$f")"
    op="$(jq -r --argjson i "$i" '.[$i].op' "$f")"
    path="$(jq -r --argjson i "$i" '.[$i].path' "$f")"
    pattern="$(jq -r --argjson i "$i" '.[$i].pattern // ""' "$f")"
    # Re-resolve containment here and USE the returned canonical path. Never
    # reconstruct "$REPO_ROOT/$path" — that would discard the containment result.
    # A path that fails now (e.g. a symlink appeared after up-front validation)
    # deterministically rejects assertion processing; it can never be PASS.
    abs="$(assertion_abs "$path")" ||
      fail ASSERTION_PATH_INVALID "assertion path escapes the worktree at run time: $path"
    cls="PASS"
    case "$op" in
      file_exists)     [ -e "$abs" ] && cls=PASS || cls=FAIL_IMPLEMENTATION ;;
      file_not_exists) [ -e "$abs" ] && cls=FAIL_IMPLEMENTATION || cls=PASS ;;
      assert_match|assert_no_match)
        if ! command -v rg >/dev/null 2>&1; then
          cls=TOOL_UNAVAILABLE
        else
          rg --no-config --no-messages -q -e "$pattern" -- "$abs" && rc=0 || rc=$?
          if [ "$op" = assert_match ]; then
            case "$rc" in 0) cls=PASS ;; 1) cls=FAIL_IMPLEMENTATION ;; *) cls=INDETERMINATE ;; esac
          else
            case "$rc" in 1) cls=PASS ;; 0) cls=FAIL_IMPLEMENTATION ;; *) cls=INDETERMINATE ;; esac
          fi
        fi
        ;;
    esac
    add_check "$(jq -cn --arg id "$id" --arg op "$op" --arg path "$path" --arg pattern "$pattern" --arg cls "$cls" \
      '{id:$id, kind:"assertion",
        assertion:{id:$id, op:$op, path:$path, pattern:(if $pattern=="" then null else $pattern end)},
        classification:$cls, failure_kind:null}')"
    update_suite_result "$cls"
  done
}

# --------------------------------------------------------------------------
# Component selection
# --------------------------------------------------------------------------

component_touched() {
  local src
  if [ "$MODE" = staged ]; then
    src="$(cand staged-manifest 2>/dev/null | jq -c '.entries')"
  else
    src="$(cand list 2>/dev/null)"
  fi
  jq -e --arg d "$1/" 'any(.[]; .path | startswith($d))' <<<"${src:-[]}" >/dev/null 2>&1
}

na_check() {
  add_check "$(jq -cn --arg id "$1" --arg r "$2" \
    '{id:$id, kind:"command", classification:"NOT_APPLICABLE", not_applicable_reason:$r, failure_kind:null}')"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: verify.sh --mode worktree|staged [--allowed P ...] [--protected P ...]
       [--contract-file ISSUE_BODY.md] [--assertions F] [--reviewed-manifest F]
       [--run-id ID] [--issue-number N] [--base-branch B] [--base-commit C]
       [--record OUT] [--repo-root DIR]
  --contract-file takes the Markdown issue body; its path contract is validated
  and extracted via issue-contract.sh.
  --base-branch / --base-commit are recorded verbatim; never derived from remotes.
EOF
  exit 2
}

emit_record() {
  local branch head fp paths enum_ok=true
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf '')"

  fp="$(cand fingerprint 2>/dev/null)" || fp=""

  # Capture and independently validate the candidate list. If enumeration cannot
  # be established, do NOT concatenate a fallback array — represent it as null and
  # mark enumeration_ok:false. The Verification Record stays valid JSON either way.
  if paths="$(cand_list_json)"; then :; else paths="null"; enum_ok=false; fi

  local rec
  rec="$(jq -cn \
    --arg mode "$MODE" \
    --arg now "$(now_utc)" \
    --arg run_id "$RUN_ID" \
    --arg issue_number "$ISSUE_NUMBER" \
    --arg repo_root "$REPO_ROOT" \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg base_branch "$BASE_BRANCH" \
    --arg base_commit "$BASE_COMMIT" \
    --arg fp "$fp" \
    --argjson paths "$paths" \
    --argjson enum_ok "$enum_ok" \
    --argjson checks "$CHECKS" \
    --arg result "$SUITE_RESULT" \
    --argjson stopped_early "$STOPPED_EARLY" \
    --argjson stopped_reason "$STOPPED_REASON" \
    '{
      schema_version: 1,
      verification_mode: $mode,
      generated_at: $now,
      run_id: (if $run_id == "" then null else $run_id end),
      issue_number: (if $issue_number == "" then null else ($issue_number|tonumber) end),
      git: {
        repo_root: $repo_root,
        branch: $branch,
        head_commit: $head,
        base_branch: (if $base_branch == "" then null else $base_branch end),
        base_commit: (if $base_commit == "" then null else $base_commit end)
      },
      candidate: {
        fingerprint: (if $fp == "" then null else $fp end),
        enumeration_ok: $enum_ok,
        paths: $paths
      },
      checks: $checks,
      result: $result,
      stopped_early: $stopped_early,
      stopped_reason: $stopped_reason
    }')"
  printf '%s\n' "$rec"
  [ -n "$RECORD_OUT" ] && printf '%s\n' "$rec" >"$RECORD_OUT"
  return 0
}

main() {
  parse_args "$@"
  REPO_ROOT="$(resolve_repo_root "$REPO_DIR")"

  # Assertions are validated up front; a bad file is rejected before any check.
  if [ -n "$ASSERTIONS_FILE" ]; then
    [ -f "$ASSERTIONS_FILE" ] || fail ASSERTION_INPUT_INVALID "assertions file not found: $ASSERTIONS_FILE"
    validate_assertions_file "$ASSERTIONS_FILE"
  fi

  # 1. candidate_scope gate (staged mode evaluates the index-vs-HEAD candidate)
  check_candidate_scope || finalize_stop

  # 1b. staged exact-match gate — before Docker / npm / Maven / assertions.
  if [ "$MODE" = staged ]; then
    check_staged_match || finalize_stop
  fi

  # 2-3. whitespace (staged mode: git diff --cached --check)
  check_tracked_whitespace
  check_untracked_whitespace || finalize_stop

  # 4. docker compose config
  run_guarded_command docker_compose_config docker compose config --quiet || finalize_stop

  # 5. assertions
  if [ -n "$ASSERTIONS_FILE" ]; then
    run_assertions "$ASSERTIONS_FILE"
  fi

  # 6-9. frontend
  if component_touched frontend; then
    run_guarded_command frontend_install npm --prefix frontend ci        || finalize_stop
    run_guarded_command frontend_lint    npm --prefix frontend run lint  || finalize_stop
    run_guarded_command frontend_test    npm --prefix frontend run test  || finalize_stop
    run_guarded_command frontend_build   npm --prefix frontend run build || finalize_stop
  else
    na_check frontend_install "no candidate path under frontend/"
    na_check frontend_lint    "no candidate path under frontend/"
    na_check frontend_test    "no candidate path under frontend/"
    na_check frontend_build   "no candidate path under frontend/"
  fi

  # 10-11. simulator
  if component_touched simulators; then
    run_guarded_command simulator_test    mvn -q -f simulators/pom.xml test               || finalize_stop
    run_guarded_command simulator_package mvn -q -f simulators/pom.xml package -DskipTests || finalize_stop
  else
    na_check simulator_test    "no candidate path under simulators/"
    na_check simulator_package "no candidate path under simulators/"
  fi

  # 12-13. backend
  if component_touched backend; then
    run_guarded_command backend_test    mvn -q -f backend/pom.xml test               || finalize_stop
    run_guarded_command backend_package mvn -q -f backend/pom.xml package -DskipTests || finalize_stop
  else
    na_check backend_test    "no candidate path under backend/"
    na_check backend_package "no candidate path under backend/"
  fi

  emit_record
  [ "$SUITE_RESULT" = PASS ]
}

main "$@"
