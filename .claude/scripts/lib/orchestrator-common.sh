#!/usr/bin/env bash
#
# orchestrator-common.sh — shared deterministic primitives for the Engineering
# Workflow v1 orchestration layer (Issue #19).
#
# Sourced by launch-issue.sh, orchestrator.sh and lifecycle.sh. It defines
# helpers only: it starts no work, reads no input, and mutates nothing at load
# time.
#
# Authority rule: orchestrator/lifecycle authority is derived ONLY from the
# inherited parent-process environment variable OMNIVISE_WORKFLOW_MODE. Prompt
# text, issue content, branch names, the working directory and model reasoning
# are never consulted, anywhere in this layer.
#
# This file carries no copy of the Issue #15 transition graph: every phase
# change goes through workflow-state.sh, which owns the graph and the counter
# caps.

# Guard against double-sourcing.
if [ -n "${_OMNIVISE_ORCH_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_OMNIVISE_ORCH_COMMON_LOADED=1

_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_SCRIPTS_DIR="$(cd "$_ORCH_LIB_DIR/.." && pwd)"

# shellcheck source=common.sh
. "$_ORCH_LIB_DIR/common.sh"

# Deterministic primitives this layer coordinates. The indirections exist so the
# offline test suite can substitute a stub for an expensive or host-touching
# boundary; they are never reachable from a Claude Bash call, which cannot set an
# environment variable (see .claude/hooks/shell-guard.sh).
ORCH_STATE_SH="${ORCH_STATE_SH:-$ORCH_SCRIPTS_DIR/workflow-state.sh}"
ORCH_CANDIDATE_SH="${ORCH_CANDIDATE_SH:-$ORCH_SCRIPTS_DIR/candidate.sh}"
ORCH_CONTRACT_SH="${ORCH_CONTRACT_SH:-$ORCH_SCRIPTS_DIR/issue-contract.sh}"
ORCH_VERIFY_SH="${ORCH_VERIFY_SH:-$ORCH_SCRIPTS_DIR/verify.sh}"
ORCH_LIFECYCLE_SH="${ORCH_LIFECYCLE_SH:-$ORCH_SCRIPTS_DIR/lifecycle.sh}"
# There is deliberately NO indirection to human-gate.sh here: no part of the
# deterministic control plane may invoke the maintainer decision entry point.
# The controller only ever READS the record human-gate.sh wrote.

# Fixed evidence file names inside the worktree-local workflow-state directory
# (<absolute-git-dir>/claude-omnivise). Workflow evidence NEVER becomes a
# candidate file: it lives beside state.json, outside the working tree.
readonly ORCH_CONTRACT_FILE_NAME="issue-contract.md"
readonly ORCH_REVIEWED_MANIFEST_NAME="reviewed-manifest.json"
readonly ORCH_RECORDS_DIR_NAME="records"
readonly ORCH_WORKTREE_RECORD_NAME="verify-worktree.json"
readonly ORCH_STAGED_RECORD_NAME="verify-staged.json"
readonly ORCH_REVIEW_RECORD_NAME="review.json"
readonly ORCH_HUMAN_GATE_RECORD_NAME="human-gate.json"
readonly ORCH_HUMAN_GATE_DECISION_NAME="human-gate-decision.json"
readonly ORCH_PR_BODY_NAME="pr-body.md"

# The maintainer Human Gate decision record (Issue #24, reopened scope). It is
# written ONLY by human-gate.sh, which is unreachable from a Claude session, and
# it is the only thing that can settle a Human Gate the immutable stored issue
# contract still declares `unresolved`. The contract itself and the recorded
# contract_hash stay byte-identical for the whole run.
readonly ORCH_HUMAN_GATE_DECISION_SCHEMA=1
readonly ORCH_MAINTAINER_DECISION_SOURCE="maintainer-decision"
readonly ORCH_MAINTAINER_APPROVED_STATUS="maintainer-approved"

# Deterministic worktree layout: a sibling of the primary checkout.
readonly ORCH_WORKTREE_DIR_NAME="omnivise-iot-worktrees"

# The fixed remote this layer talks to. Never taken from issue or model content.
readonly ORCH_REMOTE="origin"

# --------------------------------------------------------------------------
# Execution mode
# --------------------------------------------------------------------------

# orch_require_orchestrator_mode CODE — the caller may only run when the
# inherited environment says this process belongs to the deterministic
# orchestration control plane.
orch_require_orchestrator_mode() {
  local code="${1:-ORCHESTRATOR_MODE_REQUIRED}"
  [ "${OMNIVISE_WORKFLOW_MODE-}" = "orchestrator" ] ||
    fail "$code" "OMNIVISE_WORKFLOW_MODE must be 'orchestrator' (inherited from the launcher environment)"
}

# --------------------------------------------------------------------------
# Workflow state access
# --------------------------------------------------------------------------

# orch_state REPO ARGS... — run the Issue #15 state machine against REPO.
orch_state() {
  local r="$1"; shift
  bash "$ORCH_STATE_SH" --repo-root "$r" "$@"
}

# orch_state_dir REPO — the worktree-local workflow-state directory.
orch_state_dir() {
  printf '%s/claude-omnivise' "$(resolve_git_dir "$1")"
}

orch_contract_path()          { printf '%s/%s' "$(orch_state_dir "$1")" "$ORCH_CONTRACT_FILE_NAME"; }
orch_reviewed_manifest_path() { printf '%s/%s' "$(orch_state_dir "$1")" "$ORCH_REVIEWED_MANIFEST_NAME"; }
orch_records_dir()            { printf '%s/%s' "$(orch_state_dir "$1")" "$ORCH_RECORDS_DIR_NAME"; }
orch_record_path()            { printf '%s/%s' "$(orch_records_dir "$1")" "$2"; }

# orch_write_record REPO NAME JSON — persist one deterministic workflow record
# beside the state document. Records are workflow evidence, never candidate
# files, and carry only closed fields the deterministic layer produced itself.
orch_write_record() {
  local repo="$1" name="$2" json="$3" dir f
  dir="$(orch_records_dir "$repo")" || return 1
  mkdir -p "$dir" || return 1
  f="$dir/$name"
  printf '%s\n' "$json" >"$f" || return 1
  chmod 600 "$f" 2>/dev/null || true
  return 0
}

# orch_record_field FILE FILTER — read one scalar out of a persisted record.
# Returns non-zero (printing nothing) when the record is absent or the field is
# missing, empty or null, so every caller must decide explicitly what to do:
# nothing here ever substitutes a default.
orch_record_field() {
  local f="$1" filter="$2" v
  [ -f "$f" ] || return 1
  v="$(jq -r "$filter" "$f" 2>/dev/null)" || return 1
  case "$v" in "" | null) return 1 ;; esac
  printf '%s' "$v"
  return 0
}

# orch_record_provenance_ok FILE — a workflow evidence record must say which run
# and which issue produced it, in the right JSON types. `run_id` must be a
# non-empty string and `issue_number` a non-negative integer NUMBER, so a record
# carrying the string "40" is not interchangeable with the number 40. A record
# whose provenance is absent, null or the wrong type fails closed here; nothing
# is ever inferred or defaulted.
orch_record_provenance_ok() {
  jq -e '(.run_id       | type == "string" and length > 0)
         and (.issue_number | type == "number" and . == floor and . >= 0)' \
     "$1" >/dev/null 2>&1
}

# orch_gate_evidence REPO — the persisted evidence a Human Gate decision must be
# bound to. Prints eleven TAB-separated fields:
#
#   reviewed_fingerprint
#   verify_worktree_result  verify_worktree_fingerprint
#   verify_worktree_run_id  verify_worktree_issue_number
#   review_verdict  review_critical  review_major  review_fingerprint
#   review_run_id   review_issue_number
#
# Provenance (Issue #24 correction round 1) is extracted, not judged: a caller
# must still prove that both records describe the CURRENT run and issue. What is
# enforced here is that the records are structurally trustworthy at all — every
# required field present, non-null and of the right JSON type.
#
# Returns non-zero (printing nothing) when any required record is absent or a
# required field is missing or malformed. Nothing is ever defaulted, and no
# comparison is made here: the caller decides what a mismatch means.
orch_gate_evidence() {
  local repo="$1" mf wt rv fp
  local wt_res wt_fp wt_run wt_issue
  local verdict crit major rfp rv_run rv_issue

  mf="$(orch_reviewed_manifest_path "$repo")"
  fp="$(orch_record_field "$mf" '.fingerprint')" || return 1

  wt="$(orch_record_path "$repo" "$ORCH_WORKTREE_RECORD_NAME")"
  orch_record_provenance_ok "$wt" || return 1
  wt_res="$(orch_record_field "$wt" '.result')" || return 1
  wt_fp="$(orch_record_field "$wt" '.candidate.fingerprint')" || return 1
  wt_run="$(orch_record_field "$wt" '.run_id')" || return 1
  wt_issue="$(orch_record_field "$wt" '.issue_number')" || return 1

  rv="$(orch_record_path "$repo" "$ORCH_REVIEW_RECORD_NAME")"
  orch_record_provenance_ok "$rv" || return 1
  jq -e '(.verdict | type == "string")
         and (.critical | type == "number" and . == floor and . >= 0)
         and (.major    | type == "number" and . == floor and . >= 0)' \
     "$rv" >/dev/null 2>&1 || return 1
  verdict="$(orch_record_field "$rv" '.verdict')" || return 1
  crit="$(jq -r '.critical' "$rv" 2>/dev/null)" || return 1
  major="$(jq -r '.major' "$rv" 2>/dev/null)" || return 1
  rfp="$(orch_record_field "$rv" '.reviewed_fingerprint')" || return 1
  rv_run="$(orch_record_field "$rv" '.run_id')" || return 1
  rv_issue="$(orch_record_field "$rv" '.issue_number')" || return 1

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$fp" "$wt_res" "$wt_fp" "$wt_run" "$wt_issue" \
    "$verdict" "$crit" "$major" "$rfp" "$rv_run" "$rv_issue"
}

# orch_require_state REPO — the state document must exist and validate.
orch_require_state() {
  orch_state "$1" validate >/dev/null 2>&1 ||
    fail ORCHESTRATOR_STATE_INVALID "workflow state is absent or does not validate for: $1"
}

orch_phase() { orch_state "$1" get phase; }
orch_field() { orch_state "$1" get "$2"; }

# orch_require_phase REPO PHASE... — the recorded phase must be one of PHASE...
# Prints the current phase on success.
orch_require_phase() {
  local repo="$1"; shift
  local cur p
  cur="$(orch_phase "$repo")" ||
    fail ORCHESTRATOR_STATE_INVALID "could not read the recorded workflow phase"
  for p in "$@"; do
    if [ "$p" = "$cur" ]; then printf '%s' "$cur"; return 0; fi
  done
  fail ORCHESTRATOR_PHASE_MISMATCH "recorded phase '$cur' does not permit this operation (expected one of: $*)"
}

# --------------------------------------------------------------------------
# Deterministic identity derivation
# --------------------------------------------------------------------------

orch_valid_type() {
  case "${1-}" in feat | fix | refactor | test | docs | chore) return 0 ;; esac
  return 1
}

# orch_derive_type TITLE — closed, deterministic mapping from the issue title to
# a branch type. Never influenced by anything else.
orch_derive_type() {
  local t
  t="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    fix\ * | fix:* | bug\ * | bug:* | bugfix* | hotfix*) printf 'fix' ;;
    refactor*)                                           printf 'refactor' ;;
    doc\ * | docs* | document*)                          printf 'docs' ;;
    test\ * | test:* | tests*)                           printf 'test' ;;
    chore* | build* | ci\ * | ci:*)                      printf 'chore' ;;
    *)                                                   printf 'feat' ;;
  esac
}

# orch_derive_slug TITLE — lower-case, non-alphanumeric runs collapsed to '-',
# trimmed, and truncated to at most 40 characters. A truncation that would split
# a word drops that partial word, so the result never depends on where the cut
# happens to land inside a token.
readonly ORCH_SLUG_MAX=40

# Leading words that only announce the change type. They are dropped from the
# slug because the branch already carries the type, so `fix/12-fix-…` never
# happens. "add", "update" and similar meaningful verbs are deliberately absent.
readonly ORCH_TYPE_WORDS='feat feature fix bug bugfix hotfix refactor doc docs document test tests chore build ci'

orch_derive_slug() {
  local full s head w
  full="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  head="${full%%-*}"
  if [ "$head" != "$full" ]; then
    for w in $ORCH_TYPE_WORDS; do
      if [ "$w" = "$head" ]; then full="${full#*-}"; break; fi
    done
  fi
  s="$full"
  if [ "${#full}" -gt "$ORCH_SLUG_MAX" ]; then
    s="${full:0:ORCH_SLUG_MAX}"
    case "${full:ORCH_SLUG_MAX:1}" in
      -) : ;;
      *) s="${s%-*}" ;;
    esac
  fi
  printf '%s' "$(printf '%s' "$s" | sed -E 's/-+$//')"
}

orch_valid_slug() {
  case "${1-}" in
    "" | -* | *-) return 1 ;;
    *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

# orch_branch_name TYPE ISSUE SLUG
orch_branch_name() { printf '%s/%s-%s' "$1" "$2" "$3"; }

# orch_worktree_path PRIMARY_ROOT ISSUE — ../omnivise-iot-worktrees/<issue>
orch_worktree_path() {
  printf '%s/%s/%s' "$(dirname "$1")" "$ORCH_WORKTREE_DIR_NAME" "$2"
}

# --------------------------------------------------------------------------
# Run identity
# --------------------------------------------------------------------------

orch_is_uuid() {
  [[ "${1-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# orch_new_run_id — a fresh lower-case UUID. Never derived from a Claude session
# identifier or any other ambient value.
orch_new_run_id() {
  local id=""
  if command -v uuidgen >/dev/null 2>&1; then
    id="$(uuidgen 2>/dev/null || printf '')"
  fi
  if [ -z "$id" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    id="$(tr -d '\n' </proc/sys/kernel/random/uuid)"
  fi
  id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  orch_is_uuid "$id" || fail RUN_ID_UNAVAILABLE "could not generate a UUID run id"
  printf '%s' "$id"
}

# --------------------------------------------------------------------------
# Off-ramp mapping
# --------------------------------------------------------------------------

# orch_blocker_phase CODE — the closed mapping from a deterministic blocker code
# to the state-machine off-ramp it fails into. Unknown codes fail closed.
orch_blocker_phase() {
  case "${1-}" in
    CONTRACT_INVALID | CONTRACT_HASH_MISMATCH | CONTRACT_AMBIGUOUS)
      printf 'CONTRACT_CLARIFICATION_REQUIRED' ;;
    HUMAN_GATE_UNRESOLVED)
      printf 'HUMAN_DECISION_REQUIRED' ;;
    HUMAN_GATE_REJECTED)
      printf 'MANUAL_REVIEW_REQUIRED' ;;
    ENVIRONMENT_FAILURE | TOOLING_UNAVAILABLE)
      printf 'WAITING_ENVIRONMENT' ;;
    REVIEW_CORRECTION_BUDGET_EXHAUSTED | IMPL_REPAIR_BUDGET_EXHAUSTED | \
      STAGED_CANDIDATE_MISMATCH | REVIEW_BLOCKING_FINDINGS_UNRESOLVED)
      printf 'MANUAL_REVIEW_REQUIRED' ;;
    CANDIDATE_MUTATED | LIFECYCLE_FAILED | VERIFICATION_INDETERMINATE)
      printf 'FAILED' ;;
    *)
      return 1 ;;
  esac
  return 0
}

# orch_enter_offramp REPO CODE — record the blocker and transition into the
# mapped off-ramp phase. Always exits non-zero: an off-ramp is never a success.
orch_enter_offramp() {
  local repo="$1" code="$2" target
  target="$(orch_blocker_phase "$code")" ||
    fail ORCHESTRATOR_BLOCKER_UNKNOWN "unknown blocker code: $code"
  orch_state "$repo" set-blocker "$code" "$(orch_blocker_message "$code")" >/dev/null ||
    fail ORCHESTRATOR_STATE_INVALID "could not record the blocker"
  orch_state "$repo" transition "$target" >/dev/null ||
    fail ORCHESTRATOR_STATE_INVALID "could not enter the off-ramp phase: $target"
  printf '%s %s\n' "$target" "$code"
  exit 1
}

# orch_blocker_message CODE — a fixed sentence per code. Blocker text is never
# supplied by the model, the issue body, or the command line.
orch_blocker_message() {
  case "${1-}" in
    CONTRACT_INVALID)      printf 'the stored issue contract does not validate' ;;
    CONTRACT_HASH_MISMATCH) printf 'the stored issue contract no longer matches the recorded contract hash' ;;
    CONTRACT_AMBIGUOUS)    printf 'the issue contract is ambiguous and needs maintainer clarification' ;;
    HUMAN_GATE_UNRESOLVED) printf 'the issue contract carries an unresolved Human Gate' ;;
    HUMAN_GATE_REJECTED)   printf 'the maintainer rejected the Human Gate decision' ;;
    ENVIRONMENT_FAILURE)   printf 'deterministic verification reported an environment failure' ;;
    TOOLING_UNAVAILABLE)   printf 'a required verification tool is unavailable in this environment' ;;
    VERIFICATION_INDETERMINATE) printf 'deterministic verification could not establish a result' ;;
    IMPL_REPAIR_BUDGET_EXHAUSTED) printf 'the implementation repair budget is exhausted' ;;
    REVIEW_CORRECTION_BUDGET_EXHAUSTED) printf 'the review correction budget is exhausted' ;;
    STAGED_CANDIDATE_MISMATCH) printf 'the staged candidate does not match the reviewed candidate' ;;
    REVIEW_BLOCKING_FINDINGS_UNRESOLVED) printf 'blocking review findings remain unresolved' ;;
    CANDIDATE_MUTATED)     printf 'verification mutated the candidate' ;;
    LIFECYCLE_FAILED)      printf 'a deterministic Git lifecycle operation failed' ;;
    *)                     printf 'blocked' ;;
  esac
}
