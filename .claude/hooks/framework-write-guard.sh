#!/usr/bin/env bash
#
# framework-write-guard.sh — PreToolUse guard for the file-mutation tools
# (matcher: Edit|Write|MultiEdit|NotebookEdit).
#
# Policy (Issue #17, accepted Revision 5 plan + Review Correction Round 1):
#
#   canonical target is Git metadata      -> DENY in BOTH modes
#                                            (SAFETY_GIT_METADATA_MUTATION_DENIED)
#   canonical target is under .claude/    -> DENY in issue AND orchestrator mode
#                                            (SAFETY_FRAMEWORK_MUTATION_DENIED);
#                                            ALLOW in framework-maintenance mode
#   canonical target elsewhere in the repo -> ALLOW
#   canonical target outside the repo root -> DENY in BOTH modes
#                                            (SAFETY_OUTSIDE_REPO_WRITE_DENIED)
#
# framework-maintenance relaxes ONLY framework (.claude/**) writes. It never
# relaxes Git-metadata protection and never permits a write outside the project
# root (an in-repo symlink resolving outside the tree is an outside-repo write).
#
# The Issue #19 `orchestrator` mode carries Git/GitHub lifecycle authority
# through the Bash guard only. For file-tool writes it is exactly as restrictive
# as issue mode: the relaxation below is granted to framework-maintenance and to
# nothing else.
#
# Invoked as: bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/framework-write-guard.sh"
# No executable bit is required.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _here=""
if [ -z "$_here" ] || [ ! -f "$_here/guard-common.sh" ]; then
  printf 'SAFETY_INTERNAL_ERROR: guard-common.sh could not be located\n' >&2
  exit 2
fi
# shellcheck source=guard-common.sh
. "$_here/guard-common.sh" || {
  printf 'SAFETY_INTERNAL_ERROR: guard-common.sh could not be sourced\n' >&2
  exit 2
}

guard_preflight
read_payload

mode="$(mode_effective)"

target="$(field '.tool_input.file_path // ""')"
if [ -z "$target" ]; then
  target="$(field '.tool_input.notebook_path // ""')"
fi
[ -n "$target" ] || deny SAFETY_INPUT_INVALID "the file-mutation payload has neither file_path nor notebook_path"

kind="$(classify_target_path "$target")"

case "$kind" in
  git-metadata)
    deny SAFETY_GIT_METADATA_MUTATION_DENIED \
      "direct file-tool writes into Git metadata are never permitted (in any workflow mode)"
    ;;
  framework)
    if [ "$mode" != "framework-maintenance" ]; then
      deny SAFETY_FRAMEWORK_MUTATION_DENIED \
        "workflow-framework files under .claude/ cannot be modified during normal issue or orchestrator execution"
    fi
    allow
    ;;
  repo-other)
    allow
    ;;
  outside-repo)
    deny SAFETY_OUTSIDE_REPO_WRITE_DENIED \
      "file-tool writes outside the canonical project root are never permitted (in any workflow mode)"
    ;;
  *)
    deny SAFETY_INTERNAL_ERROR "the target path could not be classified"
    ;;
esac

deny SAFETY_INTERNAL_ERROR "framework-write-guard reached its end without a decision"
