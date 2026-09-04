#!/usr/bin/env bash
#
# worktree-create-guard.sh — wired to hooks.WorktreeCreate (its own event, NOT a
# PreToolUse matcher). Claude Code runs this when it would create Claude-managed
# worktree isolation (`claude --worktree`, a subagent with isolation:"worktree",
# or another Claude-managed isolated session).
#
# It performs NO worktree operation. It denies unconditionally, in every workflow
# mode and for every input:
#
#   * SAFETY_WORKTREE_LIFECYCLE_DENIED on stderr;
#   * nothing on stdout — a path on stdout would read as a successful creation;
#   * exit 2, so "WorktreeCreate hook failed" and creation is aborted.
#
# Worktree lifecycle is owned by the maintainer / the future #19 launcher, which
# creates its worktree externally before Claude starts — so this denial does not
# affect that architecture.
#
# This guard is deliberately standalone: it sources nothing, reads no stdin,
# consults no environment variable, and has no workflow-mode dependency. Every
# invocation denies, unconditionally. No executable bit is required. Invoked as:
#   bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/worktree-create-guard.sh"

set -u

printf 'SAFETY_WORKTREE_LIFECYCLE_DENIED: %s\n' \
  'Claude-managed worktree creation is denied; worktree lifecycle is owned by the maintainer / #19 launcher' >&2

exit 2
