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
# create-pr — CREATE_PR only, after the branch exists on the remote
# --------------------------------------------------------------------------

op_create_pr() {
  orch_require_phase "$REPO" CREATE_PR >/dev/null
  require_cmd gh LIFECYCLE_TOOLING_MISSING

  local branch base
  branch="$(feature_branch)"
  base="$(base_branch)"

  git_repo rev-parse --verify --quiet "refs/remotes/$ORCH_REMOTE/$branch" >/dev/null ||
    fail LIFECYCLE_NOT_PUSHED "the feature branch is not present on $ORCH_REMOTE; push first"

  local body; body="$(orch_state_dir "$REPO")/$ORCH_PR_BODY_NAME"
  {
    printf '%s\n\n' "$(subject)"
    printf 'Closes #%s\n\n' "$(orch_field "$REPO" issue_number)"
    printf 'Produced by the deterministic Engineering Workflow v1 orchestration.\n'
    printf 'Run id: %s\n' "$(orch_field "$REPO" run_id)"
    printf 'Base: %s@%s\n\n' "$base" "$(orch_field "$REPO" base_commit)"
    printf 'Human review and merge are required; this workflow never merges.\n'
  } >"$body"

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
