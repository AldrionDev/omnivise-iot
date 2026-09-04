#!/usr/bin/env bash
#
# shell-guard.sh — PreToolUse guard for the Bash tool (matcher: Bash).
#
# The policy is a strict allowlist, NOT a shell parser:
#
#   * whole-command rejection of substitution / redirection / here-doc surfaces;
#   * split into segments on  \n ; && || | &  — every segment must match a rule;
#   * a segment's first token must be exactly `git`, `bash`, or `sh`;
#       git  -> a small, fail-closed read-only argument grammar (no global
#               options, no --output / --ext-diff / --textconv, no mutating or
#               unclassified subcommand);
#       gh   -> always denied (SAFETY_GITHUB_MUTATION_DENIED);
#       bash|sh <script> -> only the four trusted read-only .claude workflow
#               entry points (issue-contract.sh, workflow-state.sh read-only
#               subcommands, candidate.sh, tests/run.sh), each with a constrained
#               per-script argument policy. verify.sh is intentionally NOT
#               reachable from a Claude Bash call — it executes component
#               verification commands against candidate-controlled files, so its
#               execution belongs to the maintainer / deterministic control
#               plane, never a Claude session.
#   * anything else -> denied.
#
# The grammar and every lifecycle denial are identical in both workflow modes;
# mode_effective runs first only so a malformed OMNIVISE_WORKFLOW_MODE fails as
# SAFETY_MODE_INVALID uniformly.
#
# On deny: "<CODE>: <reason>" on stderr, empty stdout, exit 2. On allow: silent
# exit 0. Reason strings never echo the whole command or a positional value.
#
# Invoked as: bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/shell-guard.sh"

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

# --------------------------------------------------------------------------
# Small validators
# --------------------------------------------------------------------------

# is_int_bounded VALUE — 1..4 digit non-negative integer (git -n / --max-count).
is_int_bounded() {
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 4 ]
}

# is_rev VALUE — a conservative revision token: starts alnum, then
# [A-Za-z0-9._/^~-], max 200 chars, no control chars, never a leading '-'.
is_rev() {
  case "$1" in
    "" | [!A-Za-z0-9]*) return 1 ;;
    *[!A-Za-z0-9._/^~-]*) return 1 ;;
  esac
  [ "${#1}" -le 200 ]
}

# is_range VALUE — <rev> | <rev>..<rev> | <rev>...<rev>.
is_range() {
  local r="$1"
  case "$r" in
    *...*) is_rev "${r%%...*}" && is_rev "${r##*...}" ;;
    *..*)  is_rev "${r%%..*}"  && is_rev "${r##*..}" ;;
    *)     is_rev "$r" ;;
  esac
}

# check_repo_root VALUE — a supplied --repo-root must canonicalize exactly to the
# current CLAUDE_PROJECT_DIR (symlink-resolved). Anything else is denied.
check_repo_root() {
  local v="$1" want got
  want="$(realpath -e -- "${CLAUDE_PROJECT_DIR:-}" 2>/dev/null)" || want=""
  got="$(realpath -m -- "$v" 2>/dev/null)" || got=""
  if [ -z "$want" ] || [ -z "$got" ] || [ "$want" != "$got" ]; then
    deny SAFETY_SHELL_COMMAND_DENIED "--repo-root must resolve to the current project directory"
  fi
}

# --------------------------------------------------------------------------
# Whole-command rejection and segmentation
# --------------------------------------------------------------------------

reject_dangerous_constructs() {
  case "$1" in
    *'$('*) deny SAFETY_SHELL_COMMAND_DENIED "command substitution \$(...) is not permitted" ;;
    *'`'*)  deny SAFETY_SHELL_COMMAND_DENIED "backtick command substitution is not permitted" ;;
    *'${'*) deny SAFETY_SHELL_COMMAND_DENIED "\${...} expansion is not permitted in an allowlisted command" ;;
    *'<('*) deny SAFETY_SHELL_COMMAND_DENIED "process substitution <(...) is not permitted" ;;
    *'>('*) deny SAFETY_SHELL_COMMAND_DENIED "process substitution >(...) is not permitted" ;;
    *'<<'*) deny SAFETY_SHELL_COMMAND_DENIED "here-doc / here-string is not permitted" ;;
    *'|&'*) deny SAFETY_SHELL_COMMAND_DENIED "pipe-with-stderr (|&) is not permitted" ;;
    *'&>'*) deny SAFETY_SHELL_COMMAND_DENIED "output redirection is not permitted" ;;
    *'2>'*) deny SAFETY_SHELL_COMMAND_DENIED "output redirection is not permitted" ;;
    *'>'*)  deny SAFETY_SHELL_COMMAND_DENIED "output redirection is not permitted" ;;
    *'<'*)  deny SAFETY_SHELL_COMMAND_DENIED "input redirection is not permitted" ;;
  esac
}

# split_segments COMMAND — print one trimmed, non-empty segment per line.
split_segments() {
  local s="$1" line trimmed
  s="${s//&&/$'\n'}"
  s="${s//||/$'\n'}"
  s="${s//|/$'\n'}"
  s="${s//;/$'\n'}"
  s="${s//&/$'\n'}"
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] && printf '%s\n' "$trimmed"
  done <<<"$s"
}

# --------------------------------------------------------------------------
# git read-only grammar
# --------------------------------------------------------------------------

git_grammar_status() {
  local a
  for a in "$@"; do
    case "$a" in
      --porcelain | --porcelain=v1 | --porcelain=v2 | -z | -s | --short | -b | --branch | --untracked-files=all | --no-renames) : ;;
      *) deny SAFETY_GIT_MUTATION_DENIED "git status: '$(safe_frag "$a")' is not in the permitted read-only grammar" ;;
    esac
  done
}

git_grammar_diff() {
  local a seen_ddash=0 range_seen=0
  for a in "$@"; do
    if [ "$seen_ddash" -eq 1 ]; then
      is_safe_relpath "$a" || deny SAFETY_GIT_MUTATION_DENIED "git diff: unsafe pathspec after --"
      continue
    fi
    case "$a" in
      --) seen_ddash=1 ;;
      --cached | --staged | --check | --stat | --numstat | --name-only | --name-status | --no-color) : ;;
      -*) deny SAFETY_GIT_MUTATION_DENIED "git diff: option '$(safe_frag "$a")' is not permitted" ;;
      *)
        [ "$range_seen" -eq 0 ] || deny SAFETY_GIT_MUTATION_DENIED "git diff: unexpected extra argument"
        is_range "$a" || deny SAFETY_GIT_MUTATION_DENIED "git diff: argument is not a valid revision range"
        range_seen=1
        ;;
    esac
  done
}

git_grammar_show() {
  local a pos_seen=0 rev path
  for a in "$@"; do
    case "$a" in
      --stat | --name-only | --name-status | --no-color) : ;;
      -*) deny SAFETY_GIT_MUTATION_DENIED "git show: option '$(safe_frag "$a")' is not permitted" ;;
      *)
        [ "$pos_seen" -eq 0 ] || deny SAFETY_GIT_MUTATION_DENIED "git show: only one revision argument is permitted"
        pos_seen=1
        case "$a" in
          *:*)
            rev="${a%%:*}"; path="${a#*:}"
            is_rev "$rev" || deny SAFETY_GIT_MUTATION_DENIED "git show: invalid revision in <rev>:<path>"
            is_safe_relpath "$path" || deny SAFETY_GIT_MUTATION_DENIED "git show: unsafe path in <rev>:<path>"
            ;;
          *)
            is_rev "$a" || deny SAFETY_GIT_MUTATION_DENIED "git show: argument is not a valid revision"
            ;;
        esac
        ;;
    esac
  done
}

git_grammar_log() {
  local a expect_int=0 seen_ddash=0 range_seen=0
  for a in "$@"; do
    if [ "$seen_ddash" -eq 1 ]; then
      is_safe_relpath "$a" || deny SAFETY_GIT_MUTATION_DENIED "git log: unsafe pathspec after --"
      continue
    fi
    if [ "$expect_int" -eq 1 ]; then
      is_int_bounded "$a" || deny SAFETY_GIT_MUTATION_DENIED "git log: -n requires a small integer"
      expect_int=0
      continue
    fi
    case "$a" in
      --) seen_ddash=1 ;;
      --oneline | --stat | --name-only | --no-color | --graph | --decorate) : ;;
      -n) expect_int=1 ;;
      --max-count=*)
        is_int_bounded "${a#--max-count=}" || deny SAFETY_GIT_MUTATION_DENIED "git log: --max-count requires a small integer"
        ;;
      --pretty=* | --format=*)
        case "${a#*=}" in
          oneline | short | medium | full | fuller | reference) : ;;
          *) deny SAFETY_GIT_MUTATION_DENIED "git log: --pretty/--format only accepts a named format (oneline|short|medium|full|fuller|reference)" ;;
        esac
        ;;
      -*) deny SAFETY_GIT_MUTATION_DENIED "git log: option '$(safe_frag "$a")' is not permitted" ;;
      *)
        [ "$range_seen" -eq 0 ] || deny SAFETY_GIT_MUTATION_DENIED "git log: unexpected extra argument"
        is_range "$a" || deny SAFETY_GIT_MUTATION_DENIED "git log: argument is not a valid revision range"
        range_seen=1
        ;;
    esac
  done
  [ "$expect_int" -eq 0 ] || deny SAFETY_GIT_MUTATION_DENIED "git log: -n requires a small integer"
}

git_grammar_revparse() {
  case "$#" in
    1)
      case "$1" in
        HEAD | --show-toplevel | --absolute-git-dir | --git-common-dir | --git-dir | --is-inside-work-tree | --show-prefix) : ;;
        *) deny SAFETY_GIT_MUTATION_DENIED "git rev-parse: '$(safe_frag "$1")' is not a permitted query" ;;
      esac
      ;;
    2)
      if [ "$1" = "--abbrev-ref" ] && [ "$2" = "HEAD" ]; then
        :
      elif [ "$1" = "--verify" ]; then
        is_rev "$2" || deny SAFETY_GIT_MUTATION_DENIED "git rev-parse --verify: argument is not a valid revision"
      else
        deny SAFETY_GIT_MUTATION_DENIED "git rev-parse: argument shape is not in the permitted grammar"
      fi
      ;;
    *)
      deny SAFETY_GIT_MUTATION_DENIED "git rev-parse: too many arguments for the permitted grammar"
      ;;
  esac
}

# classify_git ARGS... — ARGS are the tokens after `git`.
classify_git() {
  local sub="${1:-}"
  case "$sub" in
    "" | -*)
      deny SAFETY_GIT_MUTATION_DENIED \
        "bare 'git' or a leading global option (-c / -C / --git-dir / --work-tree / --exec-path / --no-pager / -P / ...) is not permitted; only 'git <subcommand>' read-only forms are allowed"
      ;;
  esac
  shift || true
  case "$sub" in
    status)    git_grammar_status "$@" ;;
    diff)      git_grammar_diff "$@" ;;
    show)      git_grammar_show "$@" ;;
    log)       git_grammar_log "$@" ;;
    rev-parse) git_grammar_revparse "$@" ;;
    add | stage | commit | commit-tree | push | pull | fetch | clone | switch | checkout | \
      reset | restore | clean | stash | rm | mv | am | apply | rebase | merge | cherry-pick | \
      revert | worktree | update-ref | update-index | notes | gc | prune | filter-branch | \
      filter-repo | replace | config | remote | tag | branch | init | mktree | hash-object | \
      write-tree | symbolic-ref | reflog | fast-import | send-pack | receive-pack | \
      format-patch | request-pull | bundle | daemon | http-backend | credential | \
      credential-store | credential-cache | sparse-checkout | submodule | maintenance | pack-refs)
      deny SAFETY_GIT_MUTATION_DENIED "git '$sub' is a mutating, history-rewriting, lifecycle, or exec-capable operation and is not permitted"
      ;;
    *)
      deny SAFETY_GIT_MUTATION_DENIED "git '$sub' is not part of the permitted read-only grammar"
      ;;
  esac
}

# --------------------------------------------------------------------------
# Trusted .claude workflow script argument policy
# --------------------------------------------------------------------------

script_args_run() {
  case "$#" in
    0) : ;;
    1)
      case "$1" in
        "" | -* | *[!A-Za-z0-9_-]*) deny SAFETY_SHELL_COMMAND_DENIED "tests/run.sh: the optional argument must be a simple test-name filter" ;;
      esac
      [ "${#1}" -le 64 ] || deny SAFETY_SHELL_COMMAND_DENIED "tests/run.sh: the test-name filter is too long"
      ;;
    *)
      deny SAFETY_SHELL_COMMAND_DENIED "tests/run.sh: at most one filter argument is permitted"
      ;;
  esac
}

script_args_issue_contract() {
  local op="${1:-}"
  case "$op" in
    validate | sections | paths | human-gates | hash | contract) : ;;
    *) deny SAFETY_SHELL_COMMAND_DENIED "issue-contract.sh: unknown or missing operation" ;;
  esac
  [ "$#" -le 2 ] || deny SAFETY_SHELL_COMMAND_DENIED "issue-contract.sh: too many arguments"
  if [ "$#" -eq 2 ]; then
    case "$2" in
      -) : ;;
      *) is_safe_relpath "$2" || deny SAFETY_SHELL_COMMAND_DENIED "issue-contract.sh: the issue-body argument must be '-' or a safe relative path" ;;
    esac
  fi
}

# Shared --repo-root handling for the workflow-state and candidate scripts.
_consume_repo_root() {
  # $1 = token ; sets _RR_EXPECT=1 when a following value token is required.
  case "$1" in
    --repo-root)   _RR_EXPECT=1 ;;
    --repo-root=*) check_repo_root "${1#--repo-root=}" ;;
    *)             return 1 ;;
  esac
  return 0
}

# workflow-state.sh is exposed to Claude for INSPECTION ONLY. Its own CLI
# (Issue #15) is:
#   [--repo-root DIR] <init|validate|get <field>|status|transition <PHASE>
#                      |set-blocker <CODE> <MSG>|clear-blocker
#                      |counter <name> inc|get|set-pr --number N --url U>
# Only the genuinely read-only forms are permitted here; every mutating
# subcommand, every stray flag, and every extra positional fails closed. The
# intentional state-write capability under the Git metadata directory remains
# available to the future deterministic control plane outside Claude.
script_args_workflow_state() {
  local i _RR_EXPECT=0
  local -a pos=()
  for i in "$@"; do
    if [ "$_RR_EXPECT" -eq 1 ]; then
      check_repo_root "$i"; _RR_EXPECT=0; continue
    fi
    _consume_repo_root "$i" && continue
    case "$i" in
      *[[:cntrl:]]*) deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: control character in an argument" ;;
      -*) deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: option '$(safe_frag "$i")' is not permitted (only read-only inspection is available to Claude)" ;;
      *) pos+=("$i") ;;
    esac
  done
  [ "$_RR_EXPECT" -eq 0 ] || deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: --repo-root is missing its value"

  local sub="${pos[0]:-}"
  case "$sub" in
    validate | status)
      [ "${#pos[@]}" -eq 1 ] || deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: '$sub' takes no further arguments"
      ;;
    get)
      [ "${#pos[@]}" -eq 2 ] || deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: 'get' requires exactly one field name"
      case "${pos[1]}" in
        "" | *[!a-z_]*) deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: 'get' field name must be a bare lower-case identifier" ;;
      esac
      ;;
    counter)
      [ "${#pos[@]}" -eq 3 ] || deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: 'counter' inspection requires '<name> get'"
      case "${pos[1]}" in
        "" | *[!a-z_]*) deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: 'counter' name must be a bare lower-case identifier" ;;
      esac
      [ "${pos[2]}" = "get" ] || deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: 'counter' is read-only from Claude; only '<name> get' is permitted"
      ;;
    init | transition | set-blocker | clear-blocker | set-pr)
      deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: '$sub' mutates workflow state and is not available to Claude"
      ;;
    "")
      deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: a read-only subcommand is required"
      ;;
    *)
      deny SAFETY_SHELL_COMMAND_DENIED "workflow-state.sh: unknown subcommand"
      ;;
  esac
}

script_args_candidate() {
  local i _RR_EXPECT=0 expect="" sub=""
  for i in "$@"; do
    if [ "$_RR_EXPECT" -eq 1 ]; then
      check_repo_root "$i"; _RR_EXPECT=0; continue
    fi
    if [ -n "$expect" ]; then
      case "$expect" in
        literal) is_path_contract_literal "$i" || deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: unsafe path-contract literal" ;;
        relpath) is_safe_relpath "$i" || deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: unsafe path argument" ;;
      esac
      expect=""
      continue
    fi
    _consume_repo_root "$i" && continue
    case "$i" in
      --allowed | --protected) expect="literal" ;;
      --contract-file | --reviewed-manifest) expect="relpath" ;;
      --staged) : ;;
      -*) deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: option '$(safe_frag "$i")' is not permitted" ;;
      *) [ -z "$sub" ] && sub="$i" || deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: unexpected extra argument" ;;
    esac
  done
  [ "$_RR_EXPECT" -eq 0 ] || deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: --repo-root is missing its value"
  [ -z "$expect" ] || deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: an option is missing its value"
  case "$sub" in
    list | manifest | fingerprint | staged-manifest | scope | staged-compare) : ;;
    *) deny SAFETY_SHELL_COMMAND_DENIED "candidate.sh: unknown or missing subcommand" ;;
  esac
}

# classify_script RUNNER ARGS... — RUNNER is bash|sh; ARGS start with the script.
classify_script() {
  local runner="$1"; shift
  local script="${1:-}"; shift || true
  case "$script" in
    "" | -*)
      deny SAFETY_SHELL_COMMAND_DENIED "'$runner' is only permitted to run a trusted .claude workflow script given by relative path"
      ;;
  esac
  case "$script" in
    .claude/scripts/issue-contract.sh) script_args_issue_contract "$@" ;;
    .claude/scripts/workflow-state.sh) script_args_workflow_state "$@" ;;
    .claude/scripts/candidate.sh)      script_args_candidate "$@" ;;
    .claude/tests/run.sh)              script_args_run "$@" ;;
    *)
      deny SAFETY_SHELL_COMMAND_DENIED "'$runner $script' is not one of the trusted .claude workflow entry points"
      ;;
  esac
}

# --------------------------------------------------------------------------
# Segment classification
# --------------------------------------------------------------------------

classify_segment() {
  local seg="$1"
  local -a tok=()
  read -r -a tok <<<"$seg"
  local first="${tok[0]:-}"
  case "$first" in
    git)     classify_git "${tok[@]:1}" ;;
    gh)      deny SAFETY_GITHUB_MUTATION_DENIED "the GitHub CLI (gh) is not permitted for Claude sessions; GitHub lifecycle is owned by the maintainer / future orchestrator" ;;
    bash | sh) classify_script "$first" "${tok[@]:1}" ;;
    "")      deny SAFETY_SHELL_COMMAND_DENIED "empty command segment" ;;
    *)       deny SAFETY_SHELL_COMMAND_DENIED "command '$first' is not on the safety allowlist (only read-only git and the trusted .claude workflow scripts are permitted)" ;;
  esac
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

guard_preflight
read_payload

# A malformed OMNIVISE_WORKFLOW_MODE fails as SAFETY_MODE_INVALID before any
# classification, uniformly for every command.
mode_effective >/dev/null

cmd="$(field '.tool_input.command // ""')"
[ -n "$cmd" ] || deny SAFETY_INPUT_INVALID "the Bash payload carries no command string"

reject_dangerous_constructs "$cmd"

mapfile -t _SEGMENTS < <(split_segments "$cmd")
[ "${#_SEGMENTS[@]}" -gt 0 ] || deny SAFETY_SHELL_COMMAND_DENIED "no runnable command segment was found"

for _seg in "${_SEGMENTS[@]}"; do
  classify_segment "$_seg"
done

allow
