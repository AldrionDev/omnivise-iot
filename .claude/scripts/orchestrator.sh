#!/usr/bin/env bash
#
# orchestrator.sh — the deterministic orchestration controller for Engineering
# Workflow v1 (Issue #19).
#
# This is the ONLY orchestration entry point Claude's Bash tool can reach, and
# only in OMNIVISE_WORKFLOW_MODE=orchestrator. Its argument grammar is closed:
# a single event name from a fixed list, plus `--code <FIXED_CODE>` for `block`.
# It never accepts a command, a path, a message, a phase name, or any other
# model- or issue-supplied fragment.
#
#   orchestrator.sh status
#   orchestrator.sh validate-contract          FETCH_ISSUE      -> VALIDATE_ISSUE
#   orchestrator.sh begin-plan                 VALIDATE_ISSUE   -> PLAN
#   orchestrator.sh begin-implement            PLAN             -> IMPLEMENT
#   orchestrator.sh verify-worktree            IMPLEMENT | REPAIR_IMPLEMENTATION | FIX
#                                                               -> VERIFY_WORKTREE (+routing)
#   orchestrator.sh begin-review               VERIFY_WORKTREE  -> REVIEW
#   orchestrator.sh review-pass                REVIEW           -> RESOLVE_HUMAN_GATES
#   orchestrator.sh review-changes-required    REVIEW           -> FIX
#   orchestrator.sh review-reassess            REVIEW           -> REASSESS_REVIEW
#   orchestrator.sh reassess-complete          REASSESS_REVIEW  -> REVIEW
#   orchestrator.sh gates-resolved             RESOLVE_HUMAN_GATES -> STAGE
#   orchestrator.sh stage                      STAGE            (lifecycle: stage)
#   orchestrator.sh verify-staged              STAGE            -> VERIFY_STAGED
#   orchestrator.sh commit                     VERIFY_STAGED    -> COMMIT   (lifecycle)
#   orchestrator.sh push                       COMMIT           -> PUSH     (lifecycle)
#   orchestrator.sh create-pr                  PUSH             -> CREATE_PR -> PR_READY_FOR_HUMAN_REVIEW
#   orchestrator.sh block --code CODE          any active phase -> mapped off-ramp
#   orchestrator.sh resume                     off-ramp         -> recorded resume phase
#
# The Issue #15 transition graph and the counter caps live in workflow-state.sh
# and are never re-implemented here or in a model prompt. Git and GitHub
# lifecycle mutations are never performed here either: they are delegated to
# lifecycle.sh, which re-checks mode, state and the exact phase itself.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/orchestrator-common.sh
. "$HERE/lib/orchestrator-common.sh"

require_cmd git ORCHESTRATOR_TOOLING_MISSING
require_cmd jq ORCHESTRATOR_TOOLING_MISSING

REPO=""

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

emit() {
  # emit EVENT RESULT [EXTRA_JSON]
  local extra="${3:-{\}}"
  jq -cn --arg event "$1" --arg result "$2" --arg phase "$(orch_phase "$REPO")" \
    --argjson extra "$extra" \
    '{event:$event, result:$result, phase:$phase} + $extra'
}

transition() {
  orch_state "$REPO" transition "$1" >/dev/null ||
    fail ORCHESTRATOR_TRANSITION_REJECTED "the state machine rejected the transition to $1"
}

counter_inc() {
  # counter_inc NAME — prints the new value; returns non-zero when the cap is hit.
  orch_state "$REPO" counter "$1" inc 2>/dev/null
}

contract_file() {
  local f; f="$(orch_contract_path "$REPO")"
  [ -f "$f" ] ||
    fail ORCHESTRATOR_CONTRACT_MISSING "the stored issue contract is missing from the workflow-state directory"
  printf '%s' "$f"
}

index_is_empty() {
  [ -z "$(git -C "$REPO" diff --cached --name-only)" ]
}

candidate_fingerprint() {
  bash "$ORCH_CANDIDATE_SH" --repo-root "$REPO" fingerprint
}

record_path() { printf '%s/%s' "$(orch_records_dir "$REPO")" "$1"; }

# record_classification FILE — the dominant deterministic failure classification
# in a Verification Record, or "PASS".
record_classification() {
  local f="$1" cls
  for cls in FAIL_WORKTREE_MUTATION FAIL_IMPLEMENTATION FAIL_ENVIRONMENT TOOL_UNAVAILABLE INDETERMINATE; do
    if jq -e --arg c "$cls" 'any(.checks[]?; .classification == $c)' "$f" >/dev/null 2>&1; then
      printf '%s' "$cls"; return 0
    fi
  done
  jq -r '.result' "$f"
}

# --------------------------------------------------------------------------
# Contract evaluation (deterministic; issue text is data, never instructions)
# --------------------------------------------------------------------------

contract_gate_status() {
  bash "$ORCH_CONTRACT_SH" human-gates "$(contract_file)" 2>/dev/null | jq -r '.status // "malformed"'
}

require_valid_contract() {
  local f; f="$(contract_file)"
  bash "$ORCH_CONTRACT_SH" validate "$f" >/dev/null 2>&1 ||
    orch_enter_offramp "$REPO" CONTRACT_INVALID
  local h recorded
  h="$(bash "$ORCH_CONTRACT_SH" hash "$f" 2>/dev/null)" || h=""
  recorded="$(orch_field "$REPO" contract_hash)"
  [ -n "$h" ] && [ "$h" = "$recorded" ] ||
    orch_enter_offramp "$REPO" CONTRACT_HASH_MISMATCH
}

require_gates_settled() {
  local st; st="$(contract_gate_status)"
  case "$st" in
    none | resolved) : ;;
    *) orch_enter_offramp "$REPO" HUMAN_GATE_UNRESOLVED ;;
  esac
}

# --------------------------------------------------------------------------
# Lifecycle delegation
# --------------------------------------------------------------------------

lifecycle() {
  # lifecycle OP — run the deterministic lifecycle helper. The helper re-checks
  # mode, workflow state and the exact phase; this call site adds nothing but the
  # internal invocation marker.
  env OMNIVISE_WORKFLOW_MODE=orchestrator \
      OMNIVISE_LIFECYCLE_INVOCATION=orchestrator \
      bash "$ORCH_LIFECYCLE_SH" --repo-root "$REPO" "$1"
}

# --------------------------------------------------------------------------
# Events
# --------------------------------------------------------------------------

ev_status() {
  orch_state "$REPO" status
}

ev_validate_contract() {
  orch_require_phase "$REPO" FETCH_ISSUE >/dev/null
  require_valid_contract
  require_gates_settled
  transition VALIDATE_ISSUE
  emit validate-contract OK
}

ev_begin_plan() {
  orch_require_phase "$REPO" VALIDATE_ISSUE >/dev/null
  transition PLAN
  emit begin-plan OK '{"dispatch":"planner"}'
}

ev_begin_implement() {
  orch_require_phase "$REPO" PLAN >/dev/null
  transition IMPLEMENT
  emit begin-implement OK '{"dispatch":"implementer"}'
}

ev_verify_worktree() {
  orch_require_phase "$REPO" IMPLEMENT REPAIR_IMPLEMENTATION FIX >/dev/null
  transition VERIFY_WORKTREE
  counter_inc verification_attempts >/dev/null || true

  local rec; rec="$(record_path "$ORCH_WORKTREE_RECORD_NAME")"
  mkdir -p "$(dirname "$rec")"
  local rc=0
  bash "$ORCH_VERIFY_SH" \
    --mode worktree \
    --repo-root "$REPO" \
    --contract-file "$(contract_file)" \
    --run-id "$(orch_field "$REPO" run_id)" \
    --issue-number "$(orch_field "$REPO" issue_number)" \
    --base-branch "$(orch_field "$REPO" base_branch)" \
    --base-commit "$(orch_field "$REPO" base_commit)" \
    --record "$rec" >/dev/null || rc=$?

  [ -f "$rec" ] || orch_enter_offramp "$REPO" VERIFICATION_INDETERMINATE
  cp -- "$rec" "$(record_path "verify-worktree-$(orch_field "$REPO" verification_attempts).json")" 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    emit verify-worktree PASS
    return 0
  fi

  case "$(record_classification "$rec")" in
    FAIL_WORKTREE_MUTATION) orch_enter_offramp "$REPO" CANDIDATE_MUTATED ;;
    FAIL_IMPLEMENTATION)
      if counter_inc impl_repair_attempts >/dev/null; then
        transition REPAIR_IMPLEMENTATION
        emit verify-worktree FAIL_IMPLEMENTATION \
          "$(jq -cn --argjson n "$(orch_field "$REPO" impl_repair_attempts)" \
            '{dispatch:"implementer", impl_repair_attempts:$n}')"
        exit 1
      fi
      orch_enter_offramp "$REPO" IMPL_REPAIR_BUDGET_EXHAUSTED
      ;;
    FAIL_ENVIRONMENT)  orch_enter_offramp "$REPO" ENVIRONMENT_FAILURE ;;
    TOOL_UNAVAILABLE)  orch_enter_offramp "$REPO" TOOLING_UNAVAILABLE ;;
    *)                 orch_enter_offramp "$REPO" VERIFICATION_INDETERMINATE ;;
  esac
}

ev_begin_review() {
  orch_require_phase "$REPO" VERIFY_WORKTREE >/dev/null
  # Checked before the fingerprint comparison: staging a candidate path changes
  # its tracked-ness and therefore the candidate fingerprint, so an unexpectedly
  # populated index must be reported as what it is.
  index_is_empty ||
    fail ORCHESTRATOR_INDEX_NOT_EMPTY "the Git index must be empty before an independent review"
  local rec; rec="$(record_path "$ORCH_WORKTREE_RECORD_NAME")"
  [ -f "$rec" ] ||
    fail ORCHESTRATOR_VERIFICATION_REQUIRED "no worktree Verification Record exists; run verify-worktree first"
  [ "$(jq -r '.result' "$rec")" = PASS ] ||
    fail ORCHESTRATOR_VERIFICATION_REQUIRED "the recorded worktree verification did not pass"
  # A fresh independent review is only legitimate against the exact candidate the
  # passing verification covered. A candidate that changed after a passing
  # verification is an implementation change, so it must travel the repair route
  # (VERIFY_WORKTREE -> REPAIR_IMPLEMENTATION -> VERIFY_WORKTREE) and pay for a
  # repair attempt; there is deliberately no free re-verification.
  [ "$(jq -r '.candidate.fingerprint' "$rec")" = "$(candidate_fingerprint)" ] ||
    fail ORCHESTRATOR_CANDIDATE_CHANGED "the candidate changed after the passing verification"

  counter_inc review_attempts >/dev/null || true
  transition REVIEW
  emit begin-review OK \
    "$(jq -cn --argjson n "$(orch_field "$REPO" review_attempts)" \
      '{dispatch:"reviewer", fresh:true, review_attempts:$n}')"
}

ev_review_pass() {
  orch_require_phase "$REPO" REVIEW >/dev/null
  # Capture the reviewed candidate manifest as workflow evidence, beside the
  # state document — never as a candidate file.
  local mf; mf="$(orch_reviewed_manifest_path "$REPO")"
  bash "$ORCH_CANDIDATE_SH" --repo-root "$REPO" manifest >"$mf" ||
    fail ORCHESTRATOR_MANIFEST_CAPTURE_FAILED "could not capture the reviewed candidate manifest"
  chmod 600 "$mf" 2>/dev/null || true
  local rec; rec="$(record_path "$ORCH_WORKTREE_RECORD_NAME")"
  [ "$(jq -r '.fingerprint' "$mf")" = "$(jq -r '.candidate.fingerprint' "$rec")" ] ||
    fail ORCHESTRATOR_CANDIDATE_CHANGED "the reviewed candidate no longer matches the verified candidate"

  transition RESOLVE_HUMAN_GATES
  emit review-pass OK "$(jq -cn --arg fp "$(jq -r '.fingerprint' "$mf")" '{reviewed_fingerprint:$fp}')"
}

ev_review_changes_required() {
  orch_require_phase "$REPO" REVIEW >/dev/null
  if counter_inc review_correction_rounds >/dev/null; then
    transition FIX
    emit review-changes-required OK \
      "$(jq -cn --argjson n "$(orch_field "$REPO" review_correction_rounds)" \
        '{dispatch:"implementer", review_correction_rounds:$n}')"
    return 0
  fi
  orch_enter_offramp "$REPO" REVIEW_CORRECTION_BUDGET_EXHAUSTED
}

ev_review_reassess() {
  # Evidence-only reassessment: no implementation change, so no correction round
  # is consumed.
  orch_require_phase "$REPO" REVIEW >/dev/null
  transition REASSESS_REVIEW
  emit review-reassess OK \
    "$(jq -cn --argjson n "$(orch_field "$REPO" review_correction_rounds)" \
      '{consumes_correction_round:false, review_correction_rounds:$n}')"
}

ev_reassess_complete() {
  orch_require_phase "$REPO" REASSESS_REVIEW >/dev/null
  counter_inc review_attempts >/dev/null || true
  transition REVIEW
  emit reassess-complete OK \
    "$(jq -cn --argjson n "$(orch_field "$REPO" review_attempts)" \
      '{dispatch:"reviewer", fresh:true, review_attempts:$n}')"
}

ev_gates_resolved() {
  orch_require_phase "$REPO" RESOLVE_HUMAN_GATES >/dev/null
  require_gates_settled
  [ -f "$(orch_reviewed_manifest_path "$REPO")" ] ||
    fail ORCHESTRATOR_REVIEWED_MANIFEST_MISSING "no reviewed candidate manifest was captured"
  transition STAGE
  emit gates-resolved OK
}

ev_stage() {
  orch_require_phase "$REPO" STAGE >/dev/null
  lifecycle stage >/dev/null || orch_enter_offramp "$REPO" LIFECYCLE_FAILED
  emit stage OK
}

ev_verify_staged() {
  orch_require_phase "$REPO" STAGE >/dev/null
  if index_is_empty; then
    fail ORCHESTRATOR_NOTHING_STAGED "nothing is staged; run stage first"
  fi
  transition VERIFY_STAGED

  local rec; rec="$(record_path "$ORCH_STAGED_RECORD_NAME")"
  mkdir -p "$(dirname "$rec")"
  local rc=0
  bash "$ORCH_VERIFY_SH" \
    --mode staged \
    --repo-root "$REPO" \
    --contract-file "$(contract_file)" \
    --reviewed-manifest "$(orch_reviewed_manifest_path "$REPO")" \
    --run-id "$(orch_field "$REPO" run_id)" \
    --issue-number "$(orch_field "$REPO" issue_number)" \
    --base-branch "$(orch_field "$REPO" base_branch)" \
    --base-commit "$(orch_field "$REPO" base_commit)" \
    --record "$rec" >/dev/null || rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$rec" ] && [ "$(jq -r '.result' "$rec")" = PASS ]; then
    emit verify-staged PASS
    return 0
  fi
  orch_enter_offramp "$REPO" STAGED_CANDIDATE_MISMATCH
}

ev_commit() {
  orch_require_phase "$REPO" VERIFY_STAGED >/dev/null
  local rec; rec="$(record_path "$ORCH_STAGED_RECORD_NAME")"
  [ -f "$rec" ] && [ "$(jq -r '.result' "$rec")" = PASS ] ||
    fail ORCHESTRATOR_STAGED_VERIFICATION_REQUIRED "a passing VERIFY_STAGED record is required before commit"
  transition COMMIT
  lifecycle commit >/dev/null || orch_enter_offramp "$REPO" LIFECYCLE_FAILED
  emit commit OK "$(jq -cn --arg h "$(git -C "$REPO" rev-parse HEAD)" '{head_commit:$h}')"
}

ev_push() {
  orch_require_phase "$REPO" COMMIT >/dev/null
  transition PUSH
  lifecycle push >/dev/null || orch_enter_offramp "$REPO" LIFECYCLE_FAILED
  emit push OK
}

ev_create_pr() {
  orch_require_phase "$REPO" PUSH >/dev/null
  transition CREATE_PR
  local out
  out="$(lifecycle create-pr)" || orch_enter_offramp "$REPO" LIFECYCLE_FAILED
  local number url
  number="$(printf '%s' "$out" | jq -r '.number')"
  url="$(printf '%s' "$out" | jq -r '.url')"
  case "$number" in
    ''|*[!0-9]*) orch_enter_offramp "$REPO" LIFECYCLE_FAILED ;;
  esac
  orch_state "$REPO" set-pr --number "$number" --url "$url" >/dev/null ||
    fail ORCHESTRATOR_STATE_INVALID "could not record the pull request"
  transition PR_READY_FOR_HUMAN_REVIEW
  emit create-pr OK "$(jq -cn --argjson n "$number" --arg u "$url" '{pr_number:$n, pr_url:$u}')"
}

ev_block() {
  local code="${1:-}"
  [ -n "$code" ] || fail ORCHESTRATOR_USAGE "block requires --code <CODE>"
  orch_blocker_phase "$code" >/dev/null ||
    fail ORCHESTRATOR_BLOCKER_UNKNOWN "unknown blocker code: $code"
  orch_enter_offramp "$REPO" "$code"
}

ev_resume() {
  local resume; resume="$(orch_field "$REPO" resume_phase)"
  [ -n "$resume" ] && [ "$resume" != null ] ||
    fail ORCHESTRATOR_NO_RESUME_PHASE "the recorded state carries no resume phase"
  transition "$resume"
  orch_state "$REPO" clear-blocker >/dev/null || true
  emit resume OK
}

# --------------------------------------------------------------------------
# Dispatch — closed grammar
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: orchestrator.sh <event> [--code CODE]
  status | validate-contract | begin-plan | begin-implement | verify-worktree
  begin-review | review-pass | review-changes-required | review-reassess
  reassess-complete | gates-resolved | stage | verify-staged | commit | push
  create-pr | block --code CODE | resume
EOF
  exit 2
}

main() {
  local event="${1:-}"
  shift || true

  # --repo-root is accepted only so the offline suite can drive a disposable
  # worktree; it is NOT part of the grammar the Bash guard permits.
  local code=""
  REPO="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --code)      code="${2:-}"; shift 2 ;;
      --repo-root) REPO="${2:-}"; shift 2 ;;
      *) fail ORCHESTRATOR_USAGE "unknown argument for '$event'" ;;
    esac
  done
  case "$code" in
    "" ) : ;;
    *[!A-Z0-9_]* ) fail ORCHESTRATOR_USAGE "--code must be a bare upper-case identifier" ;;
  esac

  orch_require_orchestrator_mode
  REPO="$(resolve_repo_root "$REPO")"
  orch_require_state "$REPO"

  case "$event" in
    status)                  ev_status ;;
    validate-contract)       ev_validate_contract ;;
    begin-plan)              ev_begin_plan ;;
    begin-implement)         ev_begin_implement ;;
    verify-worktree)         ev_verify_worktree ;;
    begin-review)            ev_begin_review ;;
    review-pass)             ev_review_pass ;;
    review-changes-required) ev_review_changes_required ;;
    review-reassess)         ev_review_reassess ;;
    reassess-complete)       ev_reassess_complete ;;
    gates-resolved)          ev_gates_resolved ;;
    stage)                   ev_stage ;;
    verify-staged)           ev_verify_staged ;;
    commit)                  ev_commit ;;
    push)                    ev_push ;;
    create-pr)               ev_create_pr ;;
    block)                   ev_block "$code" ;;
    resume)                  ev_resume ;;
    ''|-h|--help)            usage ;;
    *) fail ORCHESTRATOR_USAGE "unknown orchestration event" ;;
  esac
}

main "$@"
