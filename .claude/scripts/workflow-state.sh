#!/usr/bin/env bash
#
# workflow-state.sh — schema-versioned, worktree-local workflow state for the
# deterministic Claude workflow core. Mechanics only: it validates transitions
# and counters; it never decides when an agent should run, and it never creates
# worktrees or branches.
#
# State lives under the current worktree's real Git metadata directory:
#   <absolute-git-dir>/claude-omnivise/state.json
# so it is per-worktree, never tracked, never committed.
#
#   workflow-state.sh init --run-id ID --issue-number N \
#       --repo-root R --feature-branch B --base-branch BB --base-commit C \
#       --contract-hash H --allowed-path P ... --protected-path P ... \
#       [--issue-title T] [--issue-url U]
#   workflow-state.sh validate
#   workflow-state.sh get <field>
#   workflow-state.sh status
#   workflow-state.sh transition <PHASE>
#   workflow-state.sh set-blocker <CODE> <MESSAGE>
#   workflow-state.sh clear-blocker
#   workflow-state.sh counter <name> inc|get
#   workflow-state.sh set-pr --number N --url U
#
# Every command accepts --repo-root DIR to locate the worktree (default: $PWD).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

require_cmd jq WORKFLOW_STATE_TOOLING_MISSING
require_cmd git WORKFLOW_STATE_TOOLING_MISSING
require_cmd flock WORKFLOW_STATE_TOOLING_MISSING

readonly SCHEMA_VERSION=1
readonly IMPL_REPAIR_MAX=2
readonly REVIEW_CORRECTION_MAX=2

readonly PHASES='FETCH_ISSUE VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE
REPAIR_IMPLEMENTATION REVIEW REASSESS_REVIEW FIX RESOLVE_HUMAN_GATES STAGE
VERIFY_STAGED COMMIT PUSH CREATE_PR PR_READY_FOR_HUMAN_REVIEW
CONTRACT_CLARIFICATION_REQUIRED HUMAN_DECISION_REQUIRED MANUAL_REVIEW_REQUIRED
WAITING_ENVIRONMENT FAILED'

readonly REQUIRED_KEYS='schema_version run_id issue_number issue_title issue_url
repo_root feature_branch base_branch base_commit contract_hash allowed_paths
protected_paths phase resume_phase blocker_code blocker_message
impl_repair_attempts review_attempts review_correction_rounds
verification_attempts pr_number pr_url created_at updated_at'

readonly COUNTERS='impl_repair_attempts review_attempts review_correction_rounds verification_attempts'

is_known_phase() {
  local p
  for p in $PHASES; do [ "$p" = "$1" ] && return 0; done
  return 1
}

is_offramp() {
  case "$1" in
    CONTRACT_CLARIFICATION_REQUIRED|HUMAN_DECISION_REQUIRED|MANUAL_REVIEW_REQUIRED|WAITING_ENVIRONMENT) return 0 ;;
  esac
  return 1
}

# legal_transition FROM TO RESUME
legal_transition() {
  local from="$1" to="$2" resume="${3:-}" a="" x
  case "$from" in
    FETCH_ISSUE)                 a="VALIDATE_ISSUE" ;;
    VALIDATE_ISSUE)              a="PLAN" ;;
    PLAN)                        a="IMPLEMENT" ;;
    IMPLEMENT)                   a="VERIFY_WORKTREE" ;;
    VERIFY_WORKTREE)             a="REVIEW REPAIR_IMPLEMENTATION" ;;
    REPAIR_IMPLEMENTATION)       a="VERIFY_WORKTREE" ;;
    REVIEW)                      a="REASSESS_REVIEW FIX RESOLVE_HUMAN_GATES" ;;
    REASSESS_REVIEW)             a="REVIEW" ;;
    FIX)                         a="VERIFY_WORKTREE" ;;
    RESOLVE_HUMAN_GATES)         a="STAGE" ;;
    STAGE)                       a="VERIFY_STAGED" ;;
    VERIFY_STAGED)               a="COMMIT FIX" ;;
    COMMIT)                      a="PUSH" ;;
    PUSH)                        a="CREATE_PR" ;;
    CREATE_PR)                   a="PR_READY_FOR_HUMAN_REVIEW" ;;
    CONTRACT_CLARIFICATION_REQUIRED|HUMAN_DECISION_REQUIRED|MANUAL_REVIEW_REQUIRED|WAITING_ENVIRONMENT)
      a="FAILED"
      [ -n "$resume" ] && [ "$resume" != null ] && a="$a $resume"
      ;;
    FAILED|PR_READY_FOR_HUMAN_REVIEW) a="" ;;
  esac
  for x in $a; do [ "$x" = "$to" ] && return 0; done

  # Generic off-ramp: any active phase (not terminal, not itself an off-ramp)
  # may enter one of the required-decision phases or FAILED.
  case "$from" in
    FAILED|PR_READY_FOR_HUMAN_REVIEW) ;;
    CONTRACT_CLARIFICATION_REQUIRED|HUMAN_DECISION_REQUIRED|MANUAL_REVIEW_REQUIRED|WAITING_ENVIRONMENT) ;;
    *)
      case "$to" in
        CONTRACT_CLARIFICATION_REQUIRED|HUMAN_DECISION_REQUIRED|MANUAL_REVIEW_REQUIRED|WAITING_ENVIRONMENT|FAILED)
          return 0 ;;
      esac
      ;;
  esac
  return 1
}

# --------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------

REPO_DIR="$PWD"
STATE_DIR=""
STATE_FILE=""
LOCK_FILE=""

resolve_state_paths() {
  local gd
  gd="$(resolve_git_dir "$REPO_DIR")" ||
    fail WORKFLOW_STATE_GITDIR_UNRESOLVED "could not resolve the worktree Git metadata directory"
  STATE_DIR="$gd/claude-omnivise"
  STATE_FILE="$STATE_DIR/state.json"
  LOCK_FILE="$STATE_DIR/state.lock"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

LOCK_FD=""
acquire_lock() {
  ensure_state_dir
  exec {LOCK_FD}>"$LOCK_FILE"
  flock -w 30 "$LOCK_FD" || fail WORKFLOW_STATE_LOCKED "could not acquire the state lock"
}

WRITE_TMP=""
cleanup_write_tmp() { [ -n "$WRITE_TMP" ] && rm -f "$WRITE_TMP" 2>/dev/null || true; WRITE_TMP=""; }
trap cleanup_write_tmp EXIT INT TERM HUP

# write_state — read a full JSON document on stdin, validate it, replace the
# state file atomically (same filesystem).
write_state() {
  ensure_state_dir
  WRITE_TMP="$(mktemp "$STATE_DIR/.state.json.XXXXXX")"
  cat >"$WRITE_TMP"
  validate_state_doc "$WRITE_TMP"
  chmod 600 "$WRITE_TMP"
  mv -f "$WRITE_TMP" "$STATE_FILE"
  WRITE_TMP=""
}

# --------------------------------------------------------------------------
# Validation (fail-closed; never repairs)
# --------------------------------------------------------------------------

validate_state_doc() {
  local file="$1" v missing k

  jq empty "$file" >/dev/null 2>&1 ||
    fail WORKFLOW_STATE_INVALID "state file is not valid JSON"

  for k in $REQUIRED_KEYS; do
    jq -e --arg k "$k" 'has($k)' "$file" >/dev/null 2>&1 ||
      { missing="${missing:+$missing }$k"; }
  done
  [ -z "${missing:-}" ] ||
    fail WORKFLOW_STATE_INVALID "missing required field(s): $missing"

  v="$(jq -r '.schema_version' "$file")"
  [ "$v" = "$SCHEMA_VERSION" ] ||
    fail WORKFLOW_STATE_UNSUPPORTED_SCHEMA "unsupported schema version: $v"

  local types_ok
  types_ok="$(jq -r '
    (.run_id | type == "string" and (. | length) > 0) and
    (.issue_number | type == "number") and
    (.issue_title | type == "string") and
    (.issue_url | type == "string") and
    (.repo_root | type == "string") and
    (.feature_branch | type == "string") and
    (.base_branch | type == "string") and
    (.base_commit | type == "string") and
    (.contract_hash | type == "string") and
    (.allowed_paths | type == "array") and ([.allowed_paths[] | type == "string"] | all) and
    (.protected_paths | type == "array") and ([.protected_paths[] | type == "string"] | all) and
    ((.allowed_paths | length) > 0) and ((.protected_paths | length) > 0) and
    (.phase | type == "string") and
    ((.resume_phase | type) as $t | $t == "null" or $t == "string") and
    ((.blocker_code | type) as $t | $t == "null" or $t == "string") and
    ((.blocker_message | type) as $t | $t == "null" or $t == "string") and
    (.impl_repair_attempts | type == "number") and
    (.review_attempts | type == "number") and
    (.review_correction_rounds | type == "number") and
    (.verification_attempts | type == "number") and
    ((.pr_number | type) as $t | $t == "null" or $t == "number") and
    ((.pr_url | type) as $t | $t == "null" or $t == "string") and
    (.created_at | type == "string") and
    (.updated_at | type == "string")
  ' "$file")"
  [ "$types_ok" = true ] ||
    fail WORKFLOW_STATE_INVALID "state field types are invalid"

  local phase resume
  phase="$(jq -r '.phase' "$file")"
  is_known_phase "$phase" || fail WORKFLOW_STATE_INVALID "unknown phase: $phase"
  resume="$(jq -r '.resume_phase // "null"' "$file")"
  if [ "$resume" != null ]; then
    is_known_phase "$resume" || fail WORKFLOW_STATE_INVALID "unknown resume phase: $resume"
  fi

  local ira rcr rev vfy
  ira="$(jq -r '.impl_repair_attempts' "$file")"
  rcr="$(jq -r '.review_correction_rounds' "$file")"
  rev="$(jq -r '.review_attempts' "$file")"
  vfy="$(jq -r '.verification_attempts' "$file")"
  { [ "$ira" -ge 0 ] && [ "$ira" -le "$IMPL_REPAIR_MAX" ]; } ||
    fail WORKFLOW_STATE_INVALID "impl_repair_attempts out of range: $ira"
  { [ "$rcr" -ge 0 ] && [ "$rcr" -le "$REVIEW_CORRECTION_MAX" ]; } ||
    fail WORKFLOW_STATE_INVALID "review_correction_rounds out of range: $rcr"
  { [ "$rev" -ge 0 ] && [ "$vfy" -ge 0 ]; } ||
    fail WORKFLOW_STATE_INVALID "monotonic counter is negative"

  local allowed protected clash
  allowed="$(jq -r '.allowed_paths[]' "$file")"
  protected="$(jq -r '.protected_paths[]' "$file")"
  if clash="$(find_path_conflict "$allowed" "$protected")"; then
    fail WORKFLOW_STATE_INVALID "allowed and protected paths intersect: ${clash%%|*} / ${clash##*|}"
  fi
}

require_state() {
  [ -f "$STATE_FILE" ] || fail WORKFLOW_STATE_ABSENT "no workflow state at $STATE_FILE"
  validate_state_doc "$STATE_FILE"
}

sfield() { jq -r "$1" "$STATE_FILE"; }

# update_state JQ_FILTER ARGS... — apply a jq filter to the current state,
# stamp updated_at, and write atomically.
update_state() {
  local filter="$1"; shift
  jq -c "$@" --arg _now "$(now_utc)" "$filter | .updated_at = \$_now" "$STATE_FILE" | write_state
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_init() {
  local run_id="" issue_number="" issue_title="" issue_url=""
  local repo_root="" feature_branch="" base_branch="" base_commit="" contract_hash=""
  local -a allowed=() protected=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id)         run_id="${2:-}"; shift 2 ;;
      --issue-number)   issue_number="${2:-}"; shift 2 ;;
      --issue-title)    issue_title="${2:-}"; shift 2 ;;
      --issue-url)      issue_url="${2:-}"; shift 2 ;;
      --repo-root)      repo_root="${2:-}"; shift 2 ;;
      --feature-branch) feature_branch="${2:-}"; shift 2 ;;
      --base-branch)    base_branch="${2:-}"; shift 2 ;;
      --base-commit)    base_commit="${2:-}"; shift 2 ;;
      --contract-hash)  contract_hash="${2:-}"; shift 2 ;;
      --allowed-path)   allowed+=("${2:-}"); shift 2 ;;
      --protected-path) protected+=("${2:-}"); shift 2 ;;
      *) fail WORKFLOW_STATE_USAGE "unknown init argument: $1" ;;
    esac
  done

  [ -n "$run_id" ] || fail WORKFLOW_STATE_RUN_ID_REQUIRED "init requires a caller-supplied --run-id"
  case "$run_id" in
    *[!A-Za-z0-9._:-]*) fail WORKFLOW_STATE_RUN_ID_REQUIRED "run id contains unsupported characters: $run_id" ;;
  esac
  [ -n "$issue_number" ]   || fail WORKFLOW_STATE_USAGE "init requires --issue-number"
  case "$issue_number" in *[!0-9]*|'') fail WORKFLOW_STATE_USAGE "issue number must be an integer: $issue_number" ;; esac
  [ -n "$feature_branch" ] || fail WORKFLOW_STATE_USAGE "init requires --feature-branch"
  [ -n "$base_branch" ]    || fail WORKFLOW_STATE_USAGE "init requires --base-branch"
  [ -n "$base_commit" ]    || fail WORKFLOW_STATE_USAGE "init requires --base-commit"
  [ -n "$contract_hash" ]  || fail WORKFLOW_STATE_USAGE "init requires --contract-hash"
  [ "${#allowed[@]}" -gt 0 ]   || fail WORKFLOW_STATE_USAGE "init requires at least one --allowed-path"
  [ "${#protected[@]}" -gt 0 ] || fail WORKFLOW_STATE_USAGE "init requires at least one --protected-path"
  [ -n "$repo_root" ] || repo_root="$(git -C "$REPO_DIR" rev-parse --show-toplevel)"

  acquire_lock
  [ ! -f "$STATE_FILE" ] || fail WORKFLOW_STATE_EXISTS "workflow state already exists at $STATE_FILE"

  local allowed_json protected_json now
  allowed_json="$(printf '%s\n' "${allowed[@]}" | json_array_from_lines)"
  protected_json="$(printf '%s\n' "${protected[@]}" | json_array_from_lines)"
  now="$(now_utc)"

  jq -cn \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg run_id "$run_id" \
    --argjson issue_number "$issue_number" \
    --arg issue_title "$issue_title" \
    --arg issue_url "$issue_url" \
    --arg repo_root "$repo_root" \
    --arg feature_branch "$feature_branch" \
    --arg base_branch "$base_branch" \
    --arg base_commit "$base_commit" \
    --arg contract_hash "$contract_hash" \
    --argjson allowed_paths "$allowed_json" \
    --argjson protected_paths "$protected_json" \
    --arg now "$now" \
    '{
      schema_version: $schema_version,
      run_id: $run_id,
      issue_number: $issue_number,
      issue_title: $issue_title,
      issue_url: $issue_url,
      repo_root: $repo_root,
      feature_branch: $feature_branch,
      base_branch: $base_branch,
      base_commit: $base_commit,
      contract_hash: $contract_hash,
      allowed_paths: $allowed_paths,
      protected_paths: $protected_paths,
      phase: "FETCH_ISSUE",
      resume_phase: null,
      blocker_code: null,
      blocker_message: null,
      impl_repair_attempts: 0,
      review_attempts: 0,
      review_correction_rounds: 0,
      verification_attempts: 0,
      pr_number: null,
      pr_url: null,
      created_at: $now,
      updated_at: $now
    }' | write_state
  printf 'WORKFLOW_STATE_INITIALIZED\n'
}

cmd_validate() {
  require_state
  printf 'WORKFLOW_STATE_VALID\n'
}

cmd_get() {
  local field="${1:-}"
  [ -n "$field" ] || fail WORKFLOW_STATE_USAGE "get requires a field name"
  require_state
  case "$field" in
    *[!a-z_]*) fail WORKFLOW_STATE_USAGE "invalid field name: $field" ;;
  esac
  sfield ".${field} // \"\""
}

cmd_status() {
  require_state
  jq -c '.' "$STATE_FILE"
}

cmd_transition() {
  local to="${1:-}"
  [ -n "$to" ] || fail WORKFLOW_STATE_USAGE "transition requires a target phase"
  is_known_phase "$to" || fail WORKFLOW_STATE_ILLEGAL_TRANSITION "unknown phase: $to"
  acquire_lock
  require_state
  local from resume
  from="$(sfield '.phase')"
  resume="$(sfield '.resume_phase // "null"')"

  legal_transition "$from" "$to" "$resume" ||
    fail WORKFLOW_STATE_ILLEGAL_TRANSITION "transition not permitted: $from -> $to"

  local new_resume="$resume"
  if is_offramp "$to"; then
    new_resume="$from"
  elif is_offramp "$from" && [ "$to" != FAILED ]; then
    new_resume="null"
  fi

  if [ "$new_resume" = null ]; then
    update_state '.phase = $p | .resume_phase = null' --arg p "$to"
  else
    update_state '.phase = $p | .resume_phase = $r' --arg p "$to" --arg r "$new_resume"
  fi
  printf '%s\n' "$to"
}

cmd_set_blocker() {
  local code="${1:-}" msg="${2:-}"
  [ -n "$code" ] || fail WORKFLOW_STATE_USAGE "set-blocker requires a code"
  acquire_lock
  require_state
  update_state '.blocker_code = $c | .blocker_message = $m' --arg c "$code" --arg m "$msg"
  printf 'BLOCKER_SET\n'
}

cmd_clear_blocker() {
  acquire_lock
  require_state
  update_state '.blocker_code = null | .blocker_message = null'
  printf 'BLOCKER_CLEARED\n'
}

cmd_counter() {
  local name="${1:-}" op="${2:-}"
  local known=0 c
  for c in $COUNTERS; do [ "$c" = "$name" ] && known=1; done
  [ "$known" = 1 ] || fail WORKFLOW_STATE_USAGE "unknown counter: $name"
  case "$op" in
    get)
      require_state
      sfield ".${name}"
      return 0
      ;;
    inc) : ;;
    *) fail WORKFLOW_STATE_USAGE "counter op must be 'inc' or 'get'" ;;
  esac
  acquire_lock
  require_state
  local cur new max=""
  cur="$(sfield ".${name}")"
  new=$((cur + 1))
  case "$name" in
    impl_repair_attempts)     max="$IMPL_REPAIR_MAX" ;;
    review_correction_rounds) max="$REVIEW_CORRECTION_MAX" ;;
  esac
  if [ -n "$max" ] && [ "$new" -gt "$max" ]; then
    case "$name" in
      impl_repair_attempts)     fail WORKFLOW_REPAIR_LIMIT_EXCEEDED "implementation repair attempts capped at $max" ;;
      review_correction_rounds) fail WORKFLOW_REVIEW_CORRECTION_LIMIT_EXCEEDED "review correction rounds capped at $max" ;;
    esac
  fi
  update_state ".${name} = ${new}"
  printf '%s\n' "$new"
}

cmd_set_pr() {
  local number="" url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) number="${2:-}"; shift 2 ;;
      --url)    url="${2:-}"; shift 2 ;;
      *) fail WORKFLOW_STATE_USAGE "unknown set-pr argument: $1" ;;
    esac
  done
  case "$number" in *[!0-9]*|'') fail WORKFLOW_STATE_USAGE "set-pr requires an integer --number" ;; esac
  acquire_lock
  require_state
  local phase; phase="$(sfield '.phase')"
  case "$phase" in
    CREATE_PR|PR_READY_FOR_HUMAN_REVIEW) : ;;
    *) fail WORKFLOW_STATE_ILLEGAL_TRANSITION "PR data may only be recorded in CREATE_PR / PR_READY_FOR_HUMAN_REVIEW (phase: $phase)" ;;
  esac
  update_state '.pr_number = ($n | tonumber) | .pr_url = $u' --arg n "$number" --arg u "$url"
  printf 'PR_RECORDED\n'
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: workflow-state.sh [--repo-root DIR] <command> [args]
  init | validate | get <field> | status | transition <PHASE>
  set-blocker <CODE> <MSG> | clear-blocker | counter <name> inc|get
  set-pr --number N --url U
EOF
  exit 2
}

main() {
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root) REPO_DIR="${2:-}"; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  if [ "${#rest[@]}" -gt 0 ]; then set -- "${rest[@]}"; else set --; fi
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift || true
  resolve_state_paths

  case "$cmd" in
    init)          cmd_init "$@" ;;
    validate)      cmd_validate ;;
    get)           cmd_get "$@" ;;
    status)        cmd_status ;;
    transition)    cmd_transition "$@" ;;
    set-blocker)   cmd_set_blocker "$@" ;;
    clear-blocker) cmd_clear_blocker ;;
    counter)       cmd_counter "$@" ;;
    set-pr)        cmd_set_pr "$@" ;;
    -h|--help)     usage ;;
    *)             usage ;;
  esac
}

main "$@"
