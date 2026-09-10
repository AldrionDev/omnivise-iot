#!/usr/bin/env bash
#
# worktree-create-guard.sh — wired to hooks.WorktreeCreate (its own event, NOT a
# PreToolUse matcher). Claude Code runs this when it would create Claude-managed
# worktree isolation (`claude --worktree`, a subagent with isolation:"worktree",
# or another Claude-managed isolated session).
#
# It performs NO worktree operation. When OMNIVISE_WORKFLOW_MODE=orchestrator
# (the deterministic orchestrated workflow), it denies for every input:
#
#   * SAFETY_WORKTREE_LIFECYCLE_DENIED on stderr;
#   * nothing on stdout — a path on stdout would read as a successful creation;
#   * exit 2, so "WorktreeCreate hook failed" and creation is aborted.
#
# Worktree lifecycle for that workflow is owned by the maintainer / the #19
# launcher, which creates its worktree externally before Claude starts — so this
# denial does not affect that architecture.
#
# Issue #67: in every other session (OMNIVISE_WORKFLOW_MODE unset or any other
# value) the guard exits 0 immediately and Claude-managed worktree creation is
# allowed; safety then rests on maintainer discipline. Note that
# .claude/settings.json still denies the EnterWorktree / ExitWorktree tools in
# every session via permissions.deny.
#
# This guard is deliberately standalone: it sources nothing and reads no stdin;
# it consults exactly one environment variable (the mode gate above). No
# executable bit is required. Invoked as:
#   bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/worktree-create-guard.sh"

set -u

# Issue #67: the deny below applies only to the deterministic orchestrated
# workflow. Any other session (OMNIVISE_WORKFLOW_MODE unset or not "orchestrator")
# is out of scope for this guard and is handled by the maintainer directly.
if [ "${OMNIVISE_WORKFLOW_MODE-}" != "orchestrator" ]; then
  exit 0
fi

printf 'SAFETY_WORKTREE_LIFECYCLE_DENIED: %s\n' \
  'Claude-managed worktree creation is denied; worktree lifecycle is owned by the maintainer / #19 launcher' >&2

exit 2
