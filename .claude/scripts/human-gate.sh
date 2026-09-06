#!/usr/bin/env bash
#
# human-gate.sh — the maintainer-owned Human Gate decision entry point for
# Engineering Workflow v1 (Issue #24, reopened scope).
#
# WHY THIS SCRIPT EXISTS
#
# The initialized `issue-contract.md` and the recorded `state.json.contract_hash`
# are run identity: they must stay byte-identical for the whole run, and the
# deterministic PR evidence introduced by #28 depends on that. So a Human Gate
# the contract declares `unresolved` can NOT be settled by editing the contract.
# It is settled here instead, by persisting a separate structured decision record
# beside the state document — workflow-owned evidence, never a candidate file and
# never a repository file.
#
# AUTHORITY BOUNDARY
#
# The orchestrating model must not be able to approve its own Human Gate, so this
# entry point is deliberately outside everything the model can reach:
#
#   1. .claude/hooks/shell-guard.sh allowlists exactly four read-only workflow
#      scripts (plus orchestrator.sh in orchestrator mode). This script is on
#      none of those lists, so every `bash .claude/scripts/human-gate.sh ...`
#      from a Claude session is denied SAFETY_SHELL_COMMAND_DENIED, in every
#      workflow mode — the same way launch-issue.sh and lifecycle.sh are denied.
#   2. Authority is taken ONLY from the inherited parent-process environment:
#      OMNIVISE_HUMAN_GATE_INVOCATION=maintainer must already be set. A Claude
#      Bash call can neither set an environment variable nor use `env`, and the
#      orchestration event grammar carries no decision event at all.
#   3. The decision may not be taken from inside the orchestrated run's own
#      environment: an inherited OMNIVISE_WORKFLOW_MODE=orchestrator — the mode
#      every process the orchestrated session could start would inherit — is
#      refused outright.
#
# Nothing about prompt text, model output, the issue body, the branch name, the
# working directory or any other environment variable can produce authority here.
#
#   human-gate.sh [--repo-root DIR] approve
#   human-gate.sh [--repo-root DIR] reject
#
# `approve` fails closed unless the run is at the Human Gate decision point and
# every piece of evidence the approval binds to already exists and passes. The
# record it writes is a closed set of deterministic fields; maintainer prose is
# never accepted, stored, or rendered anywhere downstream.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/orchestrator-common.sh
. "$HERE/lib/orchestrator-common.sh"

require_cmd git HUMAN_GATE_TOOLING_MISSING
require_cmd jq HUMAN_GATE_TOOLING_MISSING

REPO=""
CONTRACT_HASH=""

# --------------------------------------------------------------------------
# Authority
# --------------------------------------------------------------------------

require_maintainer_authority() {
  [ "${OMNIVISE_HUMAN_GATE_INVOCATION-}" = "maintainer" ] ||
    fail HUMAN_GATE_INVOCATION_DENIED \
      "OMNIVISE_HUMAN_GATE_INVOCATION must be 'maintainer' in the inherited environment"
  [ "${OMNIVISE_WORKFLOW_MODE-}" != "orchestrator" ] ||
    fail HUMAN_GATE_ORCHESTRATED_CONTEXT_DENIED \
      "a Human Gate decision may not be taken from inside the orchestrated run's environment"
}

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------

# require_decision_point — the run must actually be at the pre-staging Human Gate
# decision point: either RESOLVE_HUMAN_GATES itself, or an off-ramp that recorded
# RESOLVE_HUMAN_GATES as its resume phase.
require_decision_point() {
  local phase resume
  phase="$(orch_phase "$REPO")" ||
    fail HUMAN_GATE_STATE_INVALID "could not read the recorded workflow phase"
  case "$phase" in
    RESOLVE_HUMAN_GATES) return 0 ;;
    CONTRACT_CLARIFICATION_REQUIRED | HUMAN_DECISION_REQUIRED | \
      MANUAL_REVIEW_REQUIRED | WAITING_ENVIRONMENT)
      resume="$(orch_field "$REPO" resume_phase)"
      [ "$resume" = RESOLVE_HUMAN_GATES ] && return 0
      ;;
  esac
  fail HUMAN_GATE_PHASE_MISMATCH \
    "recorded phase '$phase' is not the pre-staging Human Gate decision point"
}

# require_pending_gate — the stored contract must be the one the run was
# initialised with, and it must still declare an unresolved gate. A decision on a
# contract that declares `none` or `resolved` would be meaningless, and one taken
# against a drifted contract would not describe this run at all.
require_pending_gate() {
  local f h st
  f="$(orch_contract_path "$REPO")"
  [ -f "$f" ] ||
    fail HUMAN_GATE_CONTRACT_MISSING "the stored issue contract is missing from the workflow-state directory"
  h="$(bash "$ORCH_CONTRACT_SH" hash "$f" 2>/dev/null)" || h=""
  [ -n "$h" ] && [ "$h" = "$(orch_field "$REPO" contract_hash)" ] ||
    fail HUMAN_GATE_CONTRACT_HASH_MISMATCH \
      "the stored issue contract no longer matches the recorded contract hash"
  CONTRACT_HASH="$h"

  st="$(bash "$ORCH_CONTRACT_SH" human-gates "$f" 2>/dev/null | jq -r '.status // "malformed"')" ||
    st="malformed"
  [ "$st" = unresolved ] ||
    fail HUMAN_GATE_NOT_PENDING \
      "the stored issue contract declares no unresolved Human Gate (status: $st)"
}

# --------------------------------------------------------------------------
# Decision record
# --------------------------------------------------------------------------

# write_decision DECISION [EXTRA_JSON] — persist the structured decision beside
# the state document. Every field is produced by this deterministic layer; the
# caller supplies no text.
write_decision() {
  local decision="$1" extra="${2:-{\}}" json
  json="$(jq -cn \
    --argjson schema "$ORCH_HUMAN_GATE_DECISION_SCHEMA" \
    --arg src "$ORCH_MAINTAINER_DECISION_SOURCE" \
    --arg decision "$decision" \
    --arg run_id "$(orch_field "$REPO" run_id)" \
    --argjson issue "$(orch_field "$REPO" issue_number)" \
    --arg hash "$CONTRACT_HASH" \
    --arg at "$(now_utc)" \
    --argjson extra "$extra" \
    '{schema_version:$schema, source:$src, decision:$decision,
      run_id:$run_id, issue_number:$issue, contract_hash:$hash,
      recorded_at:$at} + $extra')" ||
    fail HUMAN_GATE_RECORD_FAILED "could not render the maintainer decision record"
  orch_write_record "$REPO" "$ORCH_HUMAN_GATE_DECISION_NAME" "$json" ||
    fail HUMAN_GATE_RECORD_FAILED "could not persist the maintainer decision record"
  printf '%s\n' "$json"
}

# --------------------------------------------------------------------------
# Operations
# --------------------------------------------------------------------------

op_approve() {
  require_decision_point
  require_pending_gate

  local ev run issue
  local fp wt_res wt_fp wt_run wt_issue verdict crit major rfp rv_run rv_issue
  ev="$(orch_gate_evidence "$REPO")" ||
    fail HUMAN_GATE_EVIDENCE_MISSING \
      "the run has not persisted the reviewed manifest, VERIFY_WORKTREE and review evidence an approval must bind to"
  IFS=$'\t' read -r fp wt_res wt_fp wt_run wt_issue \
                    verdict crit major rfp rv_run rv_issue <<<"$ev"

  # Provenance before content: evidence that does not belong to THIS run and
  # issue is not evidence about the decision being taken, however well its
  # fingerprints, verdict and counts happen to line up.
  run="$(orch_field "$REPO" run_id)"
  issue="$(orch_field "$REPO" issue_number)"
  { [ "$wt_run" = "$run" ] && [ "$wt_issue" = "$issue" ]; } ||
    fail HUMAN_GATE_EVIDENCE_STALE \
      "the stored VERIFY_WORKTREE record was produced for a different run or issue"
  { [ "$rv_run" = "$run" ] && [ "$rv_issue" = "$issue" ]; } ||
    fail HUMAN_GATE_EVIDENCE_STALE \
      "the stored independent review record was produced for a different run or issue"

  [ "$wt_res" = PASS ] ||
    fail HUMAN_GATE_VERIFICATION_NOT_PASSING "the recorded VERIFY_WORKTREE result is not PASS"
  [ "$wt_fp" = "$fp" ] ||
    fail HUMAN_GATE_EVIDENCE_STALE "the reviewed candidate is not the verified candidate"
  [ "$rfp" = "$fp" ] ||
    fail HUMAN_GATE_EVIDENCE_STALE "the stored review evidence describes a different candidate"
  { [ "$verdict" = PASS ] && [ "$crit" = 0 ] && [ "$major" = 0 ]; } ||
    fail HUMAN_GATE_REVIEW_NOT_ACCEPTED \
      "the stored independent review does not clear both blocking severities"

  write_decision approved "$(jq -cn \
    --arg fp "$fp" --arg wt "$wt_res" --arg wfp "$wt_fp" \
    --arg verdict "$verdict" --argjson crit "$crit" --argjson major "$major" \
    '{reviewed_fingerprint:$fp,
      verify_worktree_result:$wt, verify_worktree_fingerprint:$wfp,
      review_verdict:$verdict, review_critical:$crit, review_major:$major}')"
}

# A rejection is deliberately cheaper than an approval: a maintainer must be able
# to stop a run whose evidence is incomplete. It still binds to the run identity,
# so it can never be mistaken for a decision about a different run.
op_reject() {
  require_decision_point
  require_pending_gate
  write_decision rejected
}

# --------------------------------------------------------------------------
# Dispatch — closed grammar, no free-form argument
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: human-gate.sh [--repo-root DIR] {approve|reject}
EOF
  exit 2
}

main() {
  local op="" arg
  REPO="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root) REPO="${2:-}"; shift 2 ;;
      -h|--help)   usage ;;
      -*)          fail HUMAN_GATE_USAGE "unsupported option" ;;
      *)
        arg="$1"; shift
        [ -z "$op" ] || fail HUMAN_GATE_USAGE "exactly one decision is permitted"
        op="$arg"
        ;;
    esac
  done

  require_maintainer_authority
  REPO="$(resolve_repo_root "$REPO")"
  orch_require_state "$REPO"

  case "$op" in
    approve) op_approve ;;
    reject)  op_reject ;;
    "")      fail HUMAN_GATE_USAGE "a decision is required" ;;
    *)       fail HUMAN_GATE_UNSUPPORTED_DECISION "unsupported Human Gate decision" ;;
  esac
}

main "$@"
