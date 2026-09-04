#!/usr/bin/env bash
#
# launch-issue.sh — external maintainer/bootstrap entry point for Engineering
# Workflow v1 (Issue #19).
#
# This script runs in the PRIMARY checkout, BEFORE Claude starts. It is the only
# place where the issue branch and the issue worktree come into existence, which
# is exactly why it is outside the persisted workflow phases: worktree-local
# workflow state cannot exist before the worktree does. Worktree creation is
# therefore never recorded as a workflow phase — the first persisted phase is
# FETCH_ISSUE, written by workflow-state.sh init after the worktree exists.
#
#   launch-issue.sh --issue N --title T --contract-file F
#                   [--type TYPE] [--slug SLUG]
#                   [--base-branch main] [--issue-url URL]
#                   [--repo-root DIR] [--worktree-root DIR]
#                   [--claude-bin BIN] [--no-fetch] [--no-launch]
#
# Deterministic identity:
#   branch    <type>/<issue-number>-<slug>
#   worktree  ../omnivise-iot-worktrees/<issue-number>
#   run id    a freshly generated UUID, passed explicitly to workflow-state init
#             (never derived from a Claude session variable)
#
# Failure discipline: every precondition is checked before anything is created,
# and any failure after creation rolls the branch/worktree back. A bootstrap
# failure always exits non-zero and never launches Claude, so it can never
# continue into implementation.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/orchestrator-common.sh
. "$HERE/lib/orchestrator-common.sh"

require_cmd git LAUNCH_TOOLING_MISSING
require_cmd jq LAUNCH_TOOLING_MISSING

ISSUE=""
TITLE=""
CONTRACT_FILE=""
TYPE=""
SLUG=""
BASE_BRANCH="main"
ISSUE_URL=""
REPO_DIR="$PWD"
WORKTREE_ROOT=""
CLAUDE_BIN="${OMNIVISE_CLAUDE_BIN:-claude}"
DO_FETCH=1
DO_LAUNCH=1

usage() {
  cat >&2 <<'EOF'
Usage: launch-issue.sh --issue N --title T --contract-file F
         [--type feat|fix|refactor|test|docs|chore] [--slug SLUG]
         [--base-branch main] [--issue-url URL] [--repo-root DIR]
         [--worktree-root DIR] [--claude-bin BIN] [--no-fetch] [--no-launch]
EOF
  exit 2
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)         ISSUE="${2:-}"; shift 2 ;;
      --title)         TITLE="${2:-}"; shift 2 ;;
      --contract-file) CONTRACT_FILE="${2:-}"; shift 2 ;;
      --type)          TYPE="${2:-}"; shift 2 ;;
      --slug)          SLUG="${2:-}"; shift 2 ;;
      --base-branch)   BASE_BRANCH="${2:-}"; shift 2 ;;
      --issue-url)     ISSUE_URL="${2:-}"; shift 2 ;;
      --repo-root)     REPO_DIR="${2:-}"; shift 2 ;;
      --worktree-root) WORKTREE_ROOT="${2:-}"; shift 2 ;;
      --claude-bin)    CLAUDE_BIN="${2:-}"; shift 2 ;;
      --no-fetch)      DO_FETCH=0; shift ;;
      --no-launch)     DO_LAUNCH=0; shift ;;
      -h|--help)       usage ;;
      *) fail LAUNCH_USAGE "unknown argument: $1" ;;
    esac
  done

  [ -n "$ISSUE" ] || fail LAUNCH_ISSUE_NUMBER_REQUIRED "an explicit --issue <number> is required"
  case "$ISSUE" in
    ''|*[!0-9]*) fail LAUNCH_ISSUE_NUMBER_REQUIRED "issue number must be a positive integer: $ISSUE" ;;
  esac
  [ "$ISSUE" -gt 0 ] 2>/dev/null || fail LAUNCH_ISSUE_NUMBER_REQUIRED "issue number must be a positive integer: $ISSUE"

  [ -n "$TITLE" ] || fail LAUNCH_USAGE "--title is required (it drives deterministic type/slug derivation)"
  [ -n "$CONTRACT_FILE" ] || fail LAUNCH_USAGE "--contract-file is required"
  [ -f "$CONTRACT_FILE" ] || fail LAUNCH_CONTRACT_INVALID "contract file not found: $CONTRACT_FILE"
  [ -n "$BASE_BRANCH" ] || fail LAUNCH_USAGE "--base-branch must not be empty"

  # Checked as a precondition: a missing Claude CLI must not leave a half-built
  # branch/worktree behind.
  if [ "$DO_LAUNCH" -eq 1 ]; then
    command -v "$CLAUDE_BIN" >/dev/null 2>&1 ||
      fail LAUNCH_CLAUDE_MISSING "the Claude CLI '$CLAUDE_BIN' is not on PATH"
  fi
}

# --------------------------------------------------------------------------
# Derived identity
# --------------------------------------------------------------------------

RUN_ID=""
BRANCH=""
WORKTREE=""
PRIMARY_ROOT=""
BASE_COMMIT=""
CONTRACT_HASH=""
ALLOWED=()
PROTECTED=()

derive_identity() {
  if [ -n "$TYPE" ]; then
    orch_valid_type "$TYPE" || fail LAUNCH_USAGE "unsupported branch type: $TYPE"
  else
    TYPE="$(orch_derive_type "$TITLE")"
  fi
  if [ -z "$SLUG" ]; then
    SLUG="$(orch_derive_slug "$TITLE")"
  fi
  orch_valid_slug "$SLUG" ||
    fail LAUNCH_USAGE "the derived branch slug is empty or malformed (title: $TITLE)"
  BRANCH="$(orch_branch_name "$TYPE" "$ISSUE" "$SLUG")"
  if [ -n "$WORKTREE_ROOT" ]; then
    WORKTREE="$WORKTREE_ROOT/$ISSUE"
  else
    WORKTREE="$(orch_worktree_path "$PRIMARY_ROOT" "$ISSUE")"
  fi
}

# --------------------------------------------------------------------------
# Preconditions (all evaluated before anything is created)
# --------------------------------------------------------------------------

check_base_checkout() {
  PRIMARY_ROOT="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
    fail LAUNCH_BASE_INVALID "not inside a Git repository: $REPO_DIR"

  local cur
  cur="$(git -C "$PRIMARY_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || cur=""
  [ "$cur" = "$BASE_BRANCH" ] ||
    fail LAUNCH_BASE_INVALID "the primary checkout must be on '$BASE_BRANCH' (it is on '${cur:-<detached>}')"

  local dirty
  dirty="$(git -C "$PRIMARY_ROOT" status --porcelain --untracked-files=all)"
  [ -z "$dirty" ] ||
    fail LAUNCH_BASE_DIRTY "the primary checkout is not clean; commit or discard local changes first"
}

resolve_base_commit() {
  if [ "$DO_FETCH" -eq 1 ]; then
    git -C "$PRIMARY_ROOT" fetch --quiet "$ORCH_REMOTE" "$BASE_BRANCH" ||
      fail LAUNCH_BASE_FETCH_FAILED "could not fetch $ORCH_REMOTE/$BASE_BRANCH"
  fi
  BASE_COMMIT="$(git -C "$PRIMARY_ROOT" rev-parse --verify --quiet "refs/remotes/$ORCH_REMOTE/$BASE_BRANCH")" ||
    BASE_COMMIT=""
  [ -n "$BASE_COMMIT" ] ||
    fail LAUNCH_BASE_REF_MISSING "refs/remotes/$ORCH_REMOTE/$BASE_BRANCH does not exist; the issue branch must start from it"
}

check_collisions() {
  if git -C "$PRIMARY_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    fail LAUNCH_BRANCH_EXISTS "branch already exists: $BRANCH"
  fi
  if [ -e "$WORKTREE" ]; then
    fail LAUNCH_WORKTREE_EXISTS "worktree path already exists: $WORKTREE"
  fi
  local listed
  listed="$(git -C "$PRIMARY_ROOT" worktree list --porcelain | sed -n 's/^worktree //p')"
  local w
  while IFS= read -r w; do
    if [ -n "$w" ] && [ "$w" = "$WORKTREE" ]; then
      fail LAUNCH_WORKTREE_EXISTS "a worktree is already registered at: $WORKTREE"
    fi
  done <<EOF
$listed
EOF
}

load_contract() {
  bash "$ORCH_CONTRACT_SH" validate "$CONTRACT_FILE" >/dev/null ||
    fail LAUNCH_CONTRACT_INVALID "the issue contract does not validate: $CONTRACT_FILE"
  CONTRACT_HASH="$(bash "$ORCH_CONTRACT_SH" hash "$CONTRACT_FILE")" ||
    fail LAUNCH_CONTRACT_INVALID "could not hash the issue contract"
  local paths_json
  paths_json="$(bash "$ORCH_CONTRACT_SH" paths "$CONTRACT_FILE")" ||
    fail LAUNCH_CONTRACT_INVALID "could not extract the path contract"
  mapfile -t ALLOWED   < <(printf '%s' "$paths_json" | jq -r '.allowed[]?')
  mapfile -t PROTECTED < <(printf '%s' "$paths_json" | jq -r '.protected[]?')
  [ "${#ALLOWED[@]}" -gt 0 ] ||
    fail LAUNCH_CONTRACT_INVALID "the issue contract declares no Allowed Changed Paths"
  [ "${#PROTECTED[@]}" -gt 0 ] ||
    fail LAUNCH_CONTRACT_INVALID "the issue contract declares no Protected Paths"
}

# --------------------------------------------------------------------------
# Creation + rollback
# --------------------------------------------------------------------------

WORKTREE_CREATED=0

rollback() {
  [ "$WORKTREE_CREATED" -eq 1 ] || return 0
  git -C "$PRIMARY_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  git -C "$PRIMARY_ROOT" worktree prune >/dev/null 2>&1 || true
  rm -rf -- "$WORKTREE" 2>/dev/null || true
  git -C "$PRIMARY_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
  WORKTREE_CREATED=0
}

create_worktree() {
  mkdir -p "$(dirname "$WORKTREE")" ||
    fail LAUNCH_WORKTREE_FAILED "could not create the worktree parent directory"
  git -C "$PRIMARY_ROOT" worktree add --quiet -b "$BRANCH" "$WORKTREE" "$BASE_COMMIT" ||
    fail LAUNCH_WORKTREE_FAILED "could not create the issue worktree at $WORKTREE"
  WORKTREE_CREATED=1
}

init_state() {
  local -a args=()
  local p
  for p in "${ALLOWED[@]}";   do args+=(--allowed-path "$p"); done
  for p in "${PROTECTED[@]}"; do args+=(--protected-path "$p"); done

  # The run id is generated here and handed to workflow-state explicitly.
  RUN_ID="$(orch_new_run_id)" || { rollback; fail LAUNCH_RUN_ID_FAILED "could not generate a run id"; }

  orch_state "$WORKTREE" init \
    --run-id "$RUN_ID" \
    --issue-number "$ISSUE" \
    --issue-title "$TITLE" \
    --issue-url "$ISSUE_URL" \
    --repo-root "$WORKTREE" \
    --feature-branch "$BRANCH" \
    --base-branch "$BASE_BRANCH" \
    --base-commit "$BASE_COMMIT" \
    --contract-hash "$CONTRACT_HASH" \
    "${args[@]}" >/dev/null || {
      rollback
      fail LAUNCH_STATE_INIT_FAILED "could not initialise worktree-local workflow state"
    }

  # Store the authoritative contract next to the state document, outside the
  # candidate: it is workflow evidence, never a repository file.
  local sd; sd="$(orch_state_dir "$WORKTREE")"
  cp -- "$CONTRACT_FILE" "$sd/$ORCH_CONTRACT_FILE_NAME" || {
    rollback
    fail LAUNCH_STATE_INIT_FAILED "could not store the issue contract as workflow evidence"
  }
  chmod 600 "$sd/$ORCH_CONTRACT_FILE_NAME" 2>/dev/null || true
  mkdir -p "$sd/$ORCH_RECORDS_DIR_NAME"
}

launch_claude() {
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 ||
    fail LAUNCH_CLAUDE_MISSING "the Claude CLI '$CLAUDE_BIN' is not on PATH"
  cd "$WORKTREE"
  exec env \
    OMNIVISE_WORKFLOW_MODE=orchestrator \
    OMNIVISE_RUN_ID="$RUN_ID" \
    OMNIVISE_ISSUE_NUMBER="$ISSUE" \
    CLAUDE_PROJECT_DIR="$WORKTREE" \
    "$CLAUDE_BIN"
}

emit_summary() {
  jq -cn \
    --arg run_id "$RUN_ID" \
    --argjson issue "$ISSUE" \
    --arg branch "$BRANCH" \
    --arg worktree "$WORKTREE" \
    --arg base_branch "$BASE_BRANCH" \
    --arg base_commit "$BASE_COMMIT" \
    --arg contract_hash "$CONTRACT_HASH" \
    --arg phase "$(orch_phase "$WORKTREE")" \
    '{run_id:$run_id, issue_number:$issue, branch:$branch, worktree:$worktree,
      base_branch:$base_branch, base_commit:$base_commit,
      contract_hash:$contract_hash, phase:$phase}'
}

main() {
  parse_args "$@"
  check_base_checkout
  derive_identity
  load_contract
  resolve_base_commit
  check_collisions

  create_worktree
  init_state
  emit_summary

  if [ "$DO_LAUNCH" -eq 1 ]; then
    launch_claude
  fi
}

main "$@"
