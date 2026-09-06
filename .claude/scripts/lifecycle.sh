#!/usr/bin/env bash
#
# lifecycle.sh — the deterministic Git/GitHub lifecycle helper for Engineering
# Workflow v1 (Issue #19).
#
# This script is NOT reachable from a Claude Bash call: .claude/hooks/shell-guard.sh
# denies it explicitly in every workflow mode. It is invoked only by
# .claude/scripts/orchestrator.sh, which is itself reachable only in
# OMNIVISE_WORKFLOW_MODE=orchestrator through a closed argument grammar.
#
# Defence in depth — every operation independently re-checks:
#   1. OMNIVISE_WORKFLOW_MODE=orchestrator (inherited environment only);
#   2. the internal invocation marker set by the controller;
#   3. that worktree-local workflow state exists and validates;
#   4. that the recorded phase is EXACTLY the phase that owns this operation;
#   5. that the operation's own ordering precondition holds.
#
#   lifecycle.sh [--repo-root DIR] stage       # phase STAGE      (manifest-derived)
#   lifecycle.sh [--repo-root DIR] commit      # phase COMMIT
#   lifecycle.sh [--repo-root DIR] push        # phase PUSH
#   lifecycle.sh [--repo-root DIR] create-pr   # phase CREATE_PR
#
# There is deliberately NO merge operation, and no operation accepts a message,
# a branch, a remote, a refspec, or any other caller-supplied text: commit
# messages, PR titles and PR bodies are generated from recorded workflow state.
# `git push` is never given a force flag in any form.
#
# create-pr additionally renders the objective workflow evidence the run already
# persisted (Issue #28) and fails closed — creating no pull request — when any
# required record is absent, malformed or inconsistent with the rest.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/orchestrator-common.sh
. "$HERE/lib/orchestrator-common.sh"

require_cmd git LIFECYCLE_TOOLING_MISSING
require_cmd jq LIFECYCLE_TOOLING_MISSING

REPO=""

require_invocation() {
  orch_require_orchestrator_mode LIFECYCLE_MODE_REQUIRED
  [ "${OMNIVISE_LIFECYCLE_INVOCATION-}" = "orchestrator" ] ||
    fail LIFECYCLE_DIRECT_INVOCATION_DENIED \
      "lifecycle.sh is only callable through the deterministic orchestration controller"
}

git_repo() { git -C "$REPO" "$@"; }

index_paths() { git_repo diff --cached --name-only; }

feature_branch() { orch_field "$REPO" feature_branch; }
base_branch()    { orch_field "$REPO" base_branch; }

# commit_type — the branch type prefix, constrained to the closed set.
commit_type() {
  local b t
  b="$(feature_branch)"
  t="${b%%/*}"
  orch_valid_type "$t" || t="chore"
  printf '%s' "$t"
}

# subject — "<type>: <issue title>", collapsed to a single line.
subject() {
  local title
  title="$(orch_field "$REPO" issue_title | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [ -n "$title" ] && printf '%s: %s' "$(commit_type)" "$title" ||
    printf '%s: issue %s' "$(commit_type)" "$(orch_field "$REPO" issue_number)"
}

# --------------------------------------------------------------------------
# stage — STAGE only, manifest-derived, exactly the reviewed candidate
# --------------------------------------------------------------------------

op_stage() {
  orch_require_phase "$REPO" STAGE >/dev/null

  local mf; mf="$(orch_reviewed_manifest_path "$REPO")"
  [ -f "$mf" ] ||
    fail LIFECYCLE_REVIEWED_MANIFEST_MISSING "no reviewed candidate manifest is stored"

  [ -z "$(index_paths)" ] ||
    fail LIFECYCLE_INDEX_NOT_EMPTY "the index must be empty before manifest-derived staging"

  local reviewed_fp current_fp
  reviewed_fp="$(jq -r '.fingerprint' "$mf")"
  current_fp="$(bash "$ORCH_CANDIDATE_SH" --repo-root "$REPO" fingerprint)"
  [ -n "$reviewed_fp" ] && [ "$reviewed_fp" = "$current_fp" ] ||
    fail LIFECYCLE_CANDIDATE_CHANGED "the worktree candidate no longer matches the reviewed candidate"

  # Staging is derived from the reviewed manifest, never from a directory walk.
  # A rename contributes both sides so the deletion of the source is staged too.
  local -a paths=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    paths+=("$p")
  done < <(jq -r '.entries[] | (.path, (.rename_from // empty))' "$mf")

  [ "${#paths[@]}" -gt 0 ] ||
    fail LIFECYCLE_EMPTY_CANDIDATE "the reviewed candidate manifest lists no entries"

  GIT_LITERAL_PATHSPECS=1 git_repo add --all -- "${paths[@]}" ||
    fail LIFECYCLE_STAGE_FAILED "could not stage the reviewed candidate"

  jq -cn --arg fp "$reviewed_fp" --argjson n "${#paths[@]}" \
    '{op:"stage", reviewed_fingerprint:$fp, staged_pathspecs:$n}'
}

# --------------------------------------------------------------------------
# commit — COMMIT only, after a passing VERIFY_STAGED
# --------------------------------------------------------------------------

op_commit() {
  orch_require_phase "$REPO" COMMIT >/dev/null

  [ -n "$(index_paths)" ] ||
    fail LIFECYCLE_NOTHING_STAGED "nothing is staged; a commit would be empty"

  local msg
  msg="$(printf '%s\n\nIssue: #%s\nRun-Id: %s\n' \
    "$(subject)" "$(orch_field "$REPO" issue_number)" "$(orch_field "$REPO" run_id)")"

  git_repo commit --quiet -m "$msg" ||
    fail LIFECYCLE_COMMIT_FAILED "the commit was rejected"

  jq -cn --arg h "$(git_repo rev-parse HEAD)" '{op:"commit", head_commit:$h}'
}

# --------------------------------------------------------------------------
# push — PUSH only, after a commit exists on the feature branch
# --------------------------------------------------------------------------

op_push() {
  orch_require_phase "$REPO" PUSH >/dev/null

  local branch cur
  branch="$(feature_branch)"
  cur="$(git_repo rev-parse --abbrev-ref HEAD)"
  [ "$cur" = "$branch" ] ||
    fail LIFECYCLE_BRANCH_MISMATCH "the worktree is on '$cur' but the recorded feature branch is '$branch'"

  local head base
  head="$(git_repo rev-parse HEAD)"
  base="$(orch_field "$REPO" base_commit)"
  [ "$head" != "$base" ] ||
    fail LIFECYCLE_NOTHING_TO_PUSH "the feature branch carries no commit beyond its base"

  git_repo push --quiet --set-upstream "$ORCH_REMOTE" "$branch" ||
    fail LIFECYCLE_PUSH_FAILED "the push was rejected"

  jq -cn --arg b "$branch" --arg h "$head" '{op:"push", branch:$b, head_commit:$h}'
}

# --------------------------------------------------------------------------
# PR evidence (Issue #28)
#
# The pull-request body is assembled EXCLUSIVELY from workflow-owned persisted
# artefacts: the state document, the reviewed candidate manifest, and the
# records under <state-dir>/records/. Prompt text, model prose, branch names and
# ambient environment variables are never consulted, and no value is ever
# defaulted: a missing or inconsistent record means no pull request at all.
# --------------------------------------------------------------------------

_PR_ISSUE=""; _PR_RUN_ID=""; _PR_BASE_BRANCH=""; _PR_BASE_COMMIT=""
_PR_CONTRACT_HASH=""; _PR_REVIEWED_FP=""; _PR_WORKTREE_RESULT=""
_PR_REVIEW_VERDICT=""; _PR_REVIEW_CRITICAL=""; _PR_REVIEW_MAJOR=""
_PR_GATE_STATUS=""; _PR_STAGED_RESULT=""; _PR_STAGED_FP=""

# collect_pr_evidence — resolve every required evidence field or fail closed.
# Overwrites all _PR_* variables unconditionally, so an inherited environment
# value can never survive into the rendered body.
collect_pr_evidence() {
  local mf wt_rec review_rec gate_rec staged_rec wt_fp review_fp v
  local gate_hash gate_run gate_issue gate_fp

  _PR_ISSUE="$(orch_field "$REPO" issue_number)"
  _PR_RUN_ID="$(orch_field "$REPO" run_id)"
  _PR_BASE_BRANCH="$(base_branch)"
  _PR_BASE_COMMIT="$(orch_field "$REPO" base_commit)"
  _PR_CONTRACT_HASH="$(orch_field "$REPO" contract_hash)"
  for v in "$_PR_ISSUE" "$_PR_RUN_ID" "$_PR_BASE_BRANCH" "$_PR_BASE_COMMIT" "$_PR_CONTRACT_HASH"; do
    [ -n "$v" ] ||
      fail LIFECYCLE_EVIDENCE_MISSING "the recorded workflow state does not carry the required run identity"
  done

  # --- reviewed candidate --------------------------------------------------
  mf="$(orch_reviewed_manifest_path "$REPO")"
  _PR_REVIEWED_FP="$(orch_record_field "$mf" '.fingerprint')" ||
    fail LIFECYCLE_REVIEW_EVIDENCE_MISSING "no reviewed candidate manifest fingerprint is stored"

  # --- VERIFY_WORKTREE -----------------------------------------------------
  wt_rec="$(orch_record_path "$REPO" "$ORCH_WORKTREE_RECORD_NAME")"
  _PR_WORKTREE_RESULT="$(orch_record_field "$wt_rec" '.result')" ||
    fail LIFECYCLE_WORKTREE_VERIFICATION_EVIDENCE_MISSING \
      "no VERIFY_WORKTREE Verification Record is stored"
  [ "$_PR_WORKTREE_RESULT" = PASS ] ||
    fail LIFECYCLE_WORKTREE_VERIFICATION_EVIDENCE_MISSING \
      "the recorded VERIFY_WORKTREE result is not PASS"
  wt_fp="$(orch_record_field "$wt_rec" '.candidate.fingerprint')" ||
    fail LIFECYCLE_WORKTREE_VERIFICATION_EVIDENCE_MISSING \
      "the VERIFY_WORKTREE record carries no candidate fingerprint"
  # The reviewed candidate must be the verified candidate — the same integrity
  # relationship the controller already asserts when it captures the manifest.
  [ "$wt_fp" = "$_PR_REVIEWED_FP" ] ||
    fail LIFECYCLE_EVIDENCE_STALE \
      "the reviewed candidate fingerprint does not match the verified candidate"

  # --- independent review --------------------------------------------------
  review_rec="$(orch_record_path "$REPO" "$ORCH_REVIEW_RECORD_NAME")"
  [ -f "$review_rec" ] ||
    fail LIFECYCLE_REVIEW_EVIDENCE_MISSING "no independent review record is stored"
  jq -e '(.verdict | type == "string")
         and (.critical | type == "number" and . == floor and . >= 0)
         and (.major    | type == "number" and . == floor and . >= 0)' \
     "$review_rec" >/dev/null 2>&1 ||
    fail LIFECYCLE_REVIEW_EVIDENCE_MISSING "the stored independent review record is malformed"
  _PR_REVIEW_VERDICT="$(orch_record_field "$review_rec" '.verdict')" ||
    fail LIFECYCLE_REVIEW_EVIDENCE_MISSING "the review record carries no verdict"
  _PR_REVIEW_CRITICAL="$(jq -r '.critical' "$review_rec")"
  _PR_REVIEW_MAJOR="$(jq -r '.major' "$review_rec")"
  { [ "$_PR_REVIEW_VERDICT" = PASS ] && [ "$_PR_REVIEW_CRITICAL" = 0 ] && [ "$_PR_REVIEW_MAJOR" = 0 ]; } ||
    fail LIFECYCLE_REVIEW_EVIDENCE_MISSING \
      "the stored independent review record does not clear both blocking severities"
  review_fp="$(orch_record_field "$review_rec" '.reviewed_fingerprint')" ||
    fail LIFECYCLE_REVIEW_EVIDENCE_MISSING "the review record carries no reviewed candidate fingerprint"
  [ "$review_fp" = "$_PR_REVIEWED_FP" ] ||
    fail LIFECYCLE_EVIDENCE_STALE "the stored review evidence describes a different candidate"

  # --- Human Gate settlement ----------------------------------------------
  gate_rec="$(orch_record_path "$REPO" "$ORCH_HUMAN_GATE_RECORD_NAME")"
  _PR_GATE_STATUS="$(orch_record_field "$gate_rec" '.status')" ||
    fail LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING "no Human Gate settlement record is stored"
  # The settled states the controller can produce: a contract that declared no
  # gate, a contract that already carried a settled gate, and a gate an explicit
  # maintainer decision approved (Issue #24, reopened scope). The rendered body
  # therefore distinguishes those cases instead of flattening them.
  case "$_PR_GATE_STATUS" in
    none | resolved | "$ORCH_MAINTAINER_APPROVED_STATUS") : ;;
    *) fail LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING "the recorded Human Gate state is not settled" ;;
  esac
  gate_hash="$(orch_record_field "$gate_rec" '.contract_hash')" ||
    fail LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING "the Human Gate record carries no contract hash"
  [ "$gate_hash" = "$_PR_CONTRACT_HASH" ] ||
    fail LIFECYCLE_EVIDENCE_STALE \
      "the Human Gate evidence was recorded against a different issue contract"
  # The gate evidence must describe THIS run and the candidate that was actually
  # reviewed — the same integrity relationship every other record here carries.
  gate_run="$(orch_record_field "$gate_rec" '.run_id')" ||
    fail LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING "the Human Gate record carries no run id"
  gate_issue="$(orch_record_field "$gate_rec" '.issue_number')" ||
    fail LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING "the Human Gate record carries no issue number"
  gate_fp="$(orch_record_field "$gate_rec" '.reviewed_fingerprint')" ||
    fail LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING \
      "the Human Gate record carries no reviewed candidate fingerprint"
  { [ "$gate_run" = "$_PR_RUN_ID" ] && [ "$gate_issue" = "$_PR_ISSUE" ] &&
    [ "$gate_fp" = "$_PR_REVIEWED_FP" ]; } ||
    fail LIFECYCLE_EVIDENCE_STALE \
      "the Human Gate evidence describes a different run, issue or candidate"

  # --- VERIFY_STAGED -------------------------------------------------------
  staged_rec="$(orch_record_path "$REPO" "$ORCH_STAGED_RECORD_NAME")"
  _PR_STAGED_RESULT="$(orch_record_field "$staged_rec" '.result')" ||
    fail LIFECYCLE_STAGED_VERIFICATION_EVIDENCE_MISSING \
      "no VERIFY_STAGED Verification Record is stored"
  [ "$_PR_STAGED_RESULT" = PASS ] ||
    fail LIFECYCLE_STAGED_VERIFICATION_EVIDENCE_MISSING \
      "the recorded VERIFY_STAGED result is not PASS"
  _PR_STAGED_FP="$(orch_record_field "$staged_rec" \
    'first(.checks[]? | select(.id == "staged_match" and .classification == "PASS")
                      | .staged_evidence.staged_fingerprint)')" ||
    fail LIFECYCLE_STAGED_VERIFICATION_EVIDENCE_MISSING \
      "the VERIFY_STAGED record carries no staged candidate fingerprint"
}

# pr_body — render the evidence collected above. Every value is a variable set
# by collect_pr_evidence; nothing is read from the environment or the worktree.
pr_body() {
  printf '%s\n\n' "$(subject)"
  printf 'Closes #%s\n\n' "$_PR_ISSUE"
  printf 'Produced by the deterministic Engineering Workflow v1 orchestration.\n'
  printf 'Every value below is taken from persisted workflow state and recorded\n'
  printf 'verification/review evidence; no model-generated text contributes to it.\n\n'
  printf '## Workflow evidence\n\n'
  printf '| Field | Value |\n'
  printf '| --- | --- |\n'
  printf '| Issue | #%s |\n'                                  "$_PR_ISSUE"
  printf '| Run id | %s |\n'                                  "$_PR_RUN_ID"
  printf '| Base branch | %s |\n'                             "$_PR_BASE_BRANCH"
  printf '| Base commit | %s |\n'                             "$_PR_BASE_COMMIT"
  printf '| Contract hash | %s |\n'                           "$_PR_CONTRACT_HASH"
  printf '| Reviewed candidate fingerprint | %s |\n'          "$_PR_REVIEWED_FP"
  printf '| VERIFY_WORKTREE result | %s |\n'                  "$_PR_WORKTREE_RESULT"
  printf '| Independent review verdict | %s |\n'              "$_PR_REVIEW_VERDICT"
  printf '| Independent review Critical findings | %s |\n'    "$_PR_REVIEW_CRITICAL"
  printf '| Independent review Major findings | %s |\n'       "$_PR_REVIEW_MAJOR"
  printf '| Human Gate resolution | %s |\n'                   "$_PR_GATE_STATUS"
  printf '| VERIFY_STAGED result | %s |\n'                    "$_PR_STAGED_RESULT"
  printf '| Staged candidate fingerprint | %s |\n\n'          "$_PR_STAGED_FP"
  printf 'Human review and merge are required; this workflow never merges.\n'
}

# --------------------------------------------------------------------------
# create-pr — CREATE_PR only, after the branch exists on the remote
# --------------------------------------------------------------------------

op_create_pr() {
  orch_require_phase "$REPO" CREATE_PR >/dev/null

  # Evidence is resolved BEFORE anything is written and before GitHub is
  # contacted: incomplete or inconsistent workflow evidence means no pull
  # request is created at all.
  collect_pr_evidence

  require_cmd gh LIFECYCLE_TOOLING_MISSING

  local branch base
  branch="$(feature_branch)"
  base="$_PR_BASE_BRANCH"

  git_repo rev-parse --verify --quiet "refs/remotes/$ORCH_REMOTE/$branch" >/dev/null ||
    fail LIFECYCLE_NOT_PUSHED "the feature branch is not present on $ORCH_REMOTE; push first"

  local body; body="$(orch_state_dir "$REPO")/$ORCH_PR_BODY_NAME"
  pr_body >"$body"
  chmod 600 "$body" 2>/dev/null || true

  local out url number
  out="$(gh pr create --base "$base" --head "$branch" \
        --title "$(subject)" --body-file "$body" 2>/dev/null)" ||
    fail LIFECYCLE_PR_FAILED "the pull request could not be created"

  url="$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1 || true)"
  [ -n "$url" ] || fail LIFECYCLE_PR_FAILED "the pull-request URL could not be determined"
  number="${url##*/}"
  case "$number" in
    ''|*[!0-9]*) fail LIFECYCLE_PR_FAILED "the pull-request number could not be determined" ;;
  esac

  jq -cn --argjson n "$number" --arg u "$url" '{op:"create-pr", number:$n, url:$u}'
}

# --------------------------------------------------------------------------
# Dispatch — closed grammar, no merge operation exists
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: lifecycle.sh [--repo-root DIR] {stage|commit|push|create-pr}
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
      -*)          fail LIFECYCLE_USAGE "unsupported option" ;;
      *)
        arg="$1"; shift
        [ -z "$op" ] || fail LIFECYCLE_USAGE "exactly one lifecycle operation is permitted"
        op="$arg"
        ;;
    esac
  done

  require_invocation
  REPO="$(resolve_repo_root "$REPO")"
  orch_require_state "$REPO"

  case "$op" in
    stage)     op_stage ;;
    commit)    op_commit ;;
    push)      op_push ;;
    create-pr) op_create_pr ;;
    "")        fail LIFECYCLE_USAGE "a lifecycle operation is required" ;;
    *)         fail LIFECYCLE_UNSUPPORTED_OPERATION "unsupported lifecycle operation" ;;
  esac
}

main "$@"
