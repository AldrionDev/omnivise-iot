#!/usr/bin/env bash
#
# common.sh — shared safety-critical primitives for the deterministic workflow
# core. Sourced by issue-contract.sh, workflow-state.sh, candidate.sh, verify.sh.
#
# This file contains primitives only: diagnostics, repository/Git-metadata
# resolution, repo-relative path validation, the tiny path-contract matcher, and
# JSON emission helpers. It carries no dispatch, no persisted state, and no
# knowledge of workflow phases.
#
# Never `eval`, `bash -c`, or `sh -c` issue-, contract-, assertion-, state-, or
# repository-derived content. Path and pattern values are always data.

# fail CODE message... — print a machine-readable code + message on stderr, exit 1.
fail() {
  local code="${1:-ERROR}"
  shift || true
  printf '%s: %s\n' "$code" "$*" >&2
  exit 1
}

# require_cmd NAME [CODE] — ensure an executable is on PATH.
require_cmd() {
  local name="$1" code="${2:-TOOLING_MISSING}"
  command -v "$name" >/dev/null 2>&1 || fail "$code" "$name is required"
}

# now_utc — RFC3339 UTC timestamp (record metadata only; never a fingerprint input).
now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# resolve_repo_root [DIR] — absolute worktree root, or fail.
resolve_repo_root() {
  local dir="${1:-$PWD}" root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" ||
    fail REPO_UNRESOLVED "not inside a Git repository: $dir"
  [ -n "$root" ] || fail REPO_UNRESOLVED "could not resolve repository root: $dir"
  printf '%s' "$root"
}

# resolve_git_dir [DIR] — absolute, worktree-specific Git metadata directory.
#
# Uses `git rev-parse --absolute-git-dir` (per-worktree, always absolute) and
# cross-checks it against `git rev-parse --git-path .` so a broken Git setup is
# reported rather than guessed. `.git` is never assumed to be a directory.
resolve_git_dir() {
  local dir="${1:-$PWD}" gd check
  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" ||
    fail GITDIR_UNRESOLVED "could not resolve the Git metadata directory: $dir"
  [ -n "$gd" ] && [ -d "$gd" ] ||
    fail GITDIR_UNRESOLVED "resolved Git metadata directory is not a directory: ${gd:-<empty>}"
  check="$(git -C "$dir" rev-parse --git-path . 2>/dev/null)" || check=""
  # `--git-path .` yields "<git-dir>/." or "<git-dir>"; normalise and compare.
  check="${check%/.}"
  check="${check%/}"
  case "$check" in
    /*)
      [ "$check" = "$gd" ] ||
        fail GITDIR_UNRESOLVED "Git metadata directory resolvers disagree: $gd vs $check"
      ;;
  esac
  printf '%s' "$gd"
}

# --------------------------------------------------------------------------
# Repo-relative path validation and containment
# --------------------------------------------------------------------------

# validate_rel_path PATH [CODE] — accept only a safe repository-relative path.
# Rejects: empty, absolute, any `..` segment, leading `~`, control characters.
# A single leading `./` is tolerated and stripped by callers as needed.
validate_rel_path() {
  local p="$1" code="${2:-PATH_INVALID}"
  case "$p" in
    "")          fail "$code" "empty path" ;;
    /*)          fail "$code" "absolute path: $p" ;;
    '~'*)        fail "$code" "home-relative path: $p" ;;
    '..'|'../'*|*'/../'*|*'/..') fail "$code" "parent traversal in path: $p" ;;
  esac
  case "$p" in
    *[[:cntrl:]]*) fail "$code" "control character in path" ;;
  esac
  return 0
}

# Containment primitives. These NEVER call fail/exit: a containment check the
# caller needs to inspect returns a non-zero status, so it is safe inside command
# substitution without relying on `set -e`.
#
#   status 0 -> inside the repository; canonical path printed on stdout
#   status 1 -> resolves outside the repository (deterministic rejection)
#   status 2 -> could not be canonicalized at all
#
# Two distinct semantics:
#
#   path_within_repo      resolves the FULL target, final symlink component
#                         included. Use for assertion paths, where a final
#                         symlink escape must be rejected.
#
#   ancestor_within_repo  resolves only the PARENT/ancestor chain; the final
#                         path component is appended literally and never
#                         dereferenced. Use for candidate Git paths: a candidate
#                         symlink is authorised by its own repo-relative path,
#                         but an ancestor-directory escape must still be caught.
#
# Canonicalisation is used ONLY for containment, never as a fingerprint input.

path_within_repo() {
  local root="$1" p="$2" croot abs
  croot="$(realpath -m -- "$root" 2>/dev/null)" || return 2
  [ -n "$croot" ] || return 2
  case "$p" in
    /*) abs="$(realpath -m -- "$p" 2>/dev/null)" || return 2 ;;
    *)  abs="$(realpath -m -- "$croot/$p" 2>/dev/null)" || return 2 ;;
  esac
  [ -n "$abs" ] || return 2
  case "$abs" in
    "$croot") printf '%s' "$abs"; return 0 ;;
    "$croot"/*) printf '%s' "$abs"; return 0 ;;
  esac
  return 1
}

ancestor_within_repo() {
  local root="$1" rel="$2" croot parent base pabs
  croot="$(realpath -m -- "$root" 2>/dev/null)" || return 2
  [ -n "$croot" ] || return 2
  rel="${rel#./}"
  rel="${rel%/}"
  [ -n "$rel" ] || return 2
  case "$rel" in /*) return 1 ;; esac
  case "$rel" in
    */*) parent="${rel%/*}"; base="${rel##*/}" ;;
    *)   parent="";          base="$rel" ;;
  esac
  [ -n "$base" ] || return 2
  case "$base" in .|..) return 2 ;; esac
  if [ -n "$parent" ]; then
    pabs="$(realpath -m -- "$croot/$parent" 2>/dev/null)" || return 2
  else
    pabs="$croot"
  fi
  [ -n "$pabs" ] || return 2
  case "$pabs" in
    "$croot") : ;;
    "$croot"/*) : ;;
    *) return 1 ;;
  esac
  printf '%s/%s' "$pabs" "$base"
  return 0
}

# canonicalize_within REPO_ROOT PATH [CODE] — fatal wrapper around
# path_within_repo for callers that want exit-on-failure semantics.
canonicalize_within() {
  local root="$1" p="$2" code="${3:-PATH_OUTSIDE_REPO}" abs
  abs="$(path_within_repo "$root" "$p")" ||
    fail "$code" "path resolves outside the repository (or is uncanonicalizable): $p"
  printf '%s' "$abs"
}

# path_matches REL ENTRY — the tiny path-contract matcher.
#   ENTRY ending in "/**"  -> matches any REL under that directory prefix
#   otherwise (literal)    -> matches iff REL is exactly ENTRY
# ENTRY is compared as a quoted literal, never as a glob.
path_matches() {
  local rel="$1" entry="$2" prefix
  case "$entry" in
    */'**')
      prefix="${entry%'**'}"        # keeps the trailing slash: "dir/"
      case "$rel" in
        "$prefix"?*) return 0 ;;
      esac
      ;;
    *)
      [ "$rel" = "$entry" ] && return 0
      ;;
  esac
  return 1
}

# --------------------------------------------------------------------------
# Path-contract intersection (shared by issue-contract.sh and workflow-state.sh)
# --------------------------------------------------------------------------

# _entry_kind ENTRY -> "prefix <core>" | "literal <core>"
_entry_kind() {
  case "$1" in
    */'**') printf 'prefix %s' "${1%'/**'}" ;;
    *)      printf 'literal %s' "$1" ;;
  esac
}

# paths_intersect AKIND ACORE QKIND QCORE -> 0 when the two entry path-sets
# intersect (see the accepted plan's conflict table).
paths_intersect() {
  local ak="$1" ac="$2" qk="$3" qc="$4"
  if [ "$ak" = literal ] && [ "$qk" = literal ]; then
    [ "$ac" = "$qc" ]
  elif [ "$ak" = literal ] && [ "$qk" = prefix ]; then
    case "$ac" in "$qc"/?*) return 0 ;; esac; return 1
  elif [ "$ak" = prefix ] && [ "$qk" = literal ]; then
    case "$qc" in "$ac"/?*) return 0 ;; esac; return 1
  else
    case "$qc/" in "$ac"/*) return 0 ;; esac
    case "$ac/" in "$qc"/*) return 0 ;; esac
    return 1
  fi
}

# find_path_conflict "<allowed newline list>" "<protected newline list>"
# prints "ALLOWED|PROTECTED" for the first intersecting pair and returns 0,
# otherwise returns 1.
find_path_conflict() {
  local a q ak ac qk qc
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    read -r ak ac <<<"$(_entry_kind "$a")"
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      read -r qk qc <<<"$(_entry_kind "$q")"
      if paths_intersect "$ak" "$ac" "$qk" "$qc"; then
        printf '%s|%s' "$a" "$q"
        return 0
      fi
    done <<<"$2"
  done <<<"$1"
  return 1
}

# --------------------------------------------------------------------------
# JSON helpers (jq only; shell never hand-builds JSON)
# --------------------------------------------------------------------------

# json_array_from_lines — read newline-delimited items on stdin, emit a compact
# JSON string array (empty lines dropped).
json_array_from_lines() {
  jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# json_string VALUE — emit VALUE as a JSON string.
json_string() {
  jq -cn --arg v "$1" '$v'
}
