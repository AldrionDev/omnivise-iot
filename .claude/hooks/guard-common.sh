#!/usr/bin/env bash
#
# guard-common.sh — shared, fail-closed primitives for the Claude workflow
# safety guards (Issue #17).
#
# This file is *sourced*, never executed. It defines helpers only; it starts no
# work and reads no input at load time. The three guard scripts
# (framework-write-guard.sh, shell-guard.sh, worktree-create-guard.sh) source it
# and drive the decision.
#
# Design rules:
#   * Every helper that cannot produce a trustworthy answer calls `deny` — it
#     never falls through to `allow`.
#   * `deny` prints "<STABLE_CODE>: <reason>" to stderr, keeps stdout empty, and
#     exits 2 (the exit status a PreToolUse command hook uses to block a call).
#   * Reason strings name only the classified fragment (tool, mode, subcommand,
#     option, path kind). They never echo a whole command or arbitrary argument
#     value, which could carry a credential.
#   * Execution mode is derived ONLY from the parent process environment variable
#     OMNIVISE_WORKFLOW_MODE — never from stdin, tool input, cwd, transcript,
#     branch name, or issue text.

# Guard against double-sourcing.
if [ -n "${_OMNIVISE_GUARD_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_OMNIVISE_GUARD_COMMON_LOADED=1

# --------------------------------------------------------------------------
# Decision signalling
# --------------------------------------------------------------------------

# deny CODE reason... — stable code + reason on stderr, empty stdout, exit 2.
deny() {
  local code="${1:-SAFETY_INTERNAL_ERROR}"
  shift || true
  printf '%s: %s\n' "$code" "$*" >&2
  exit 2
}

# allow — silent success.
allow() {
  exit 0
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

# guard_preflight — the guards depend on jq, realpath, and git. A missing tool is
# a fail-closed internal error, never a silent allow.
guard_preflight() {
  local t
  for t in jq realpath git; do
    command -v "$t" >/dev/null 2>&1 || {
      printf 'SAFETY_INTERNAL_ERROR: required tool missing: %s\n' "$t" >&2
      exit 2
    }
  done
}

# --------------------------------------------------------------------------
# Hook payload
# --------------------------------------------------------------------------

# _GUARD_PAYLOAD holds the raw stdin JSON after read_payload.
_GUARD_PAYLOAD=""

# read_payload — slurp stdin and require a JSON object carrying a tool_input
# object. Anything else is SAFETY_INPUT_INVALID.
read_payload() {
  _GUARD_PAYLOAD="$(cat)"
  printf '%s' "$_GUARD_PAYLOAD" \
    | jq -e 'type == "object" and (.tool_input | type == "object")' >/dev/null 2>&1 \
    || deny SAFETY_INPUT_INVALID "hook payload is not a JSON object with a tool_input object"
}

# field JQ_PATH — print a string field from the payload (jq -r). A jq failure is
# SAFETY_INPUT_INVALID. Use a `// ""` default in the expression for optional
# fields.
field() {
  printf '%s' "$_GUARD_PAYLOAD" | jq -r "$1" 2>/dev/null \
    || deny SAFETY_INPUT_INVALID "could not read a required field from the tool payload"
}

# --------------------------------------------------------------------------
# Execution mode
# --------------------------------------------------------------------------

# mode_effective — print the effective workflow mode, or deny SAFETY_MODE_INVALID.
#
#   unset / empty         -> issue   (fail-closed default; not an error)
#   issue                 -> issue
#   framework-maintenance -> framework-maintenance
#   orchestrator          -> orchestrator   (Issue #19 control plane)
#   anything else         -> SAFETY_MODE_INVALID, exit 2
#
# Reads ONLY ${OMNIVISE_WORKFLOW_MODE-}. No other source of authority: never the
# prompt, the issue body, the branch name, the working directory, or model
# reasoning.
#
# `orchestrator` is NOT a relaxation of the file-tool policy. It is exactly as
# restrictive as issue mode for Edit/Write (.claude/** denied, Git metadata
# denied, outside-repo denied); it only authorizes the single fixed deterministic
# orchestration entry point through the Bash guard.
mode_effective() {
  case "${OMNIVISE_WORKFLOW_MODE-}" in
    "" | issue)            printf 'issue' ;;
    framework-maintenance) printf 'framework-maintenance' ;;
    orchestrator)          printf 'orchestrator' ;;
    *)
      deny SAFETY_MODE_INVALID \
        "OMNIVISE_WORKFLOW_MODE has an unrecognized value; expected it unset, 'issue', 'framework-maintenance', or 'orchestrator'"
      ;;
  esac
}

# --------------------------------------------------------------------------
# Repository / Git-metadata resolution
# --------------------------------------------------------------------------

# _repo_root — absolute project root. Prefers CLAUDE_PROJECT_DIR (the value the
# hook process inherits); otherwise falls back to `git rev-parse --show-toplevel`.
# Returns non-zero when neither is available (caller denies SAFETY_PATH_UNRESOLVED).
_repo_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  local r
  r="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}

# _git_metadata_roots ROOT — print the canonical, de-duplicated set of directories
# that constitute this checkout's Git metadata, one per line:
#
#   * `git -C ROOT rev-parse --absolute-git-dir` (per-worktree Git dir; for a
#     linked worktree this can be OUTSIDE ROOT)
#   * `git -C ROOT rev-parse --git-common-dir`   (shared Git dir)
#   * ROOT/.git                                  (the `.git` entry itself — a dir
#     in a normal checkout, a file in a linked worktree; writing that file is an
#     attack, so it is always protected)
#
# Fail-closed guardrail: ROOT already resolved to a real directory, so
# `git rev-parse` MUST be able to name the metadata dir. If BOTH rev-parse
# queries fail, this returns non-zero and the caller denies — it never degrades
# to "protect the lexical .git only and otherwise allow".
_git_metadata_roots() {
  local root="$1" q v abs got=0
  local -a out=()
  for q in --absolute-git-dir --git-common-dir; do
    v="$(git -C "$root" rev-parse "$q" 2>/dev/null)" || continue
    [ -n "$v" ] || continue
    case "$v" in
      /*) : ;;
      *)  v="$root/$v" ;;
    esac
    abs="$(realpath -m -- "$v" 2>/dev/null)" || continue
    [ -n "$abs" ] && { out+=("$abs"); got=1; }
  done

  abs="$(realpath -m -- "$root/.git" 2>/dev/null)" || abs=""
  [ -n "$abs" ] && out+=("$abs")

  [ "$got" -eq 1 ] || return 1
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

# classify_target_path RAW — canonicalize a file-tool destination and print its
# class:
#
#   git-metadata   canonical target is ROOT/.git, a Git metadata root, or a
#                  descendant of one (checked FIRST — a linked worktree's real
#                  Git dir can be anywhere)
#   framework      canonical target is ROOT/.claude or a descendant
#   repo-other     canonical target is ROOT itself or any other descendant of ROOT
#   outside-repo   canonical target resolves outside ROOT entirely — an absolute
#                  path elsewhere, a `..` escape, or an in-repo symlink whose real
#                  destination is outside the project
#
# Containment is path-segment safe: the `"$root" | "$root"/*` match means
# `/repo-other` is NOT treated as inside `/repo`.
#
# `realpath -m` resolves `.`/`..` and existing symlink components in the prefix,
# so there is no separate `..`-rejection rule and an in-repo symlink pointing
# outside the tree is classified outside-repo. Any failure to canonicalize, or an
# unresolved root, or an untrustworthy Git-metadata set, denies (never allows).
classify_target_path() {
  local raw="$1" root cand abs roots mr

  case "$raw" in
    *[[:cntrl:]]*) deny SAFETY_INPUT_INVALID "control character in the target path" ;;
  esac

  root="$(_repo_root)" || deny SAFETY_PATH_UNRESOLVED "cannot determine the project/repository root"
  root="$(realpath -e -- "$root" 2>/dev/null)" \
    || deny SAFETY_PATH_UNRESOLVED "the project root does not resolve to a real directory"
  [ -n "$root" ] || deny SAFETY_PATH_UNRESOLVED "the project root does not resolve to a real directory"

  case "$raw" in
    /*) cand="$raw" ;;
    *)  cand="$root/$raw" ;;
  esac
  abs="$(realpath -m -- "$cand" 2>/dev/null)" \
    || deny SAFETY_PATH_UNRESOLVED "the target path cannot be canonicalized"
  [ -n "$abs" ] || deny SAFETY_PATH_UNRESOLVED "the target path cannot be canonicalized"

  roots="$(_git_metadata_roots "$root")" \
    || deny SAFETY_PATH_UNRESOLVED "the canonical Git metadata roots cannot be determined for this repository"

  while IFS= read -r mr; do
    [ -n "$mr" ] || continue
    case "$abs" in
      "$mr" | "$mr"/*) printf 'git-metadata'; return 0 ;;
    esac
  done <<EOF
$roots
EOF

  case "$abs" in
    "$root/.claude" | "$root/.claude"/*) printf 'framework'; return 0 ;;
  esac

  case "$abs" in
    "$root" | "$root"/*) printf 'repo-other'; return 0 ;;
  esac

  printf 'outside-repo'
  return 0
}

# --------------------------------------------------------------------------
# Small shared value validators (used by shell-guard argument policy)
# --------------------------------------------------------------------------

# is_safe_relpath VALUE — a plain, in-tree relative path: not empty, not
# absolute, no leading '-', no '..' segment, no control characters. Lightweight
# lexical check for read-only pathspec / file arguments (never a write target).
is_safe_relpath() {
  case "$1" in
    "" | -* | /*)                return 1 ;;
    *[[:cntrl:]]*)               return 1 ;;
    '..' | '../'* | *'/../'* | *'/..') return 1 ;;
  esac
  return 0
}

# is_path_contract_literal VALUE — a path-contract entry: [A-Za-z0-9._/*+@-]+
is_path_contract_literal() {
  case "$1" in
    "" | *[!A-Za-z0-9._/*+@-]*) return 1 ;;
  esac
  return 0
}

# safe_frag TOKEN — echo an option token as-is, but mask a positional value so a
# credential-bearing argument is never reflected in a reason string.
safe_frag() {
  case "$1" in
    -*) printf '%s' "$1" ;;
    *)  printf '<argument>' ;;
  esac
}
