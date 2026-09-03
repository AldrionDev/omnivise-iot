#!/usr/bin/env bash
#
# candidate.sh — deterministic, complete working-tree candidate inspection.
#
#   candidate.sh list                 # complete candidate, JSON array
#   candidate.sh manifest             # { "fingerprint", "entries":[...] }  (worktree)
#   candidate.sh fingerprint          # "sha256:<hex>" over the COMPLETE candidate
#   candidate.sh scope   --allowed P ... --protected P ...   # classification only
#   candidate.sh scope   --contract-file F
#   candidate.sh staged-manifest      # { "fingerprint", "entries":[...] }  (index vs HEAD)
#   candidate.sh staged-compare --reviewed-manifest F
#
# list / manifest / fingerprint always cover the COMPLETE candidate and take no
# scope filter. Scope classification is a separate operation.
#
# All commands accept --repo-root DIR (default: $PWD). Git output is parsed
# NUL-delimited; filenames are never split on whitespace or newlines.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

require_cmd git CANDIDATE_TOOLING_MISSING
require_cmd jq CANDIDATE_TOOLING_MISSING
require_cmd sha256sum CANDIDATE_TOOLING_MISSING
require_cmd readlink CANDIDATE_TOOLING_MISSING

REPO_DIR="$PWD"
REPO_ROOT=""

resolve_root() {
  REPO_ROOT="$(resolve_repo_root "$REPO_DIR")"
}

readonly ZERO_SHA='0000000000000000000000000000000000000000'

mode_type() {
  case "$1" in
    120000) printf 'symlink' ;;
    160000) printf 'gitlink' ;;
    000000) printf 'deleted' ;;
    *)      printf 'file' ;;
  esac
}

mode_class() {
  case "$1" in
    120000) printf 'symlink' ;;
    160000) printf 'gitlink' ;;
    000000) printf 'none' ;;
    *)      printf 'file' ;;
  esac
}

# worktree_content_id REL MODE — canonical content id for a worktree entry.
worktree_content_id() {
  local rel="$1" mode="$2" abs="$REPO_ROOT/$1"
  case "$mode" in
    120000) readlink -n -- "$abs" | git hash-object --stdin ;;
    160000)
      if [ -e "$abs/.git" ] || [ -f "$abs/.git" ]; then
        git -C "$abs" rev-parse HEAD 2>/dev/null || printf '%s' "$ZERO_SHA"
      else
        printf '%s' "$ZERO_SHA"
      fi
      ;;
    *)
      if [ -L "$abs" ]; then
        readlink -n -- "$abs" | git hash-object --stdin
      elif [ -e "$abs" ]; then
        git hash-object -- "$abs"
      else
        printf '%s' "$ZERO_SHA"
      fi
      ;;
  esac
}

# emit_entry — print one compact JSON object built from the canonical fields.
emit_entry() {
  local path="$1" tracked="$2" change_type="$3" mode="$4" etype="$5" \
        content_id="$6" rename_from="$7" source_mode="$8" source_content_id="$9" \
        mode_change="${10}" type_change="${11}"
  jq -cn \
    --arg path "$path" \
    --argjson tracked "$tracked" \
    --arg change_type "$change_type" \
    --arg mode "$mode" \
    --arg type "$etype" \
    --arg content_id "$content_id" \
    --arg rename_from "$rename_from" \
    --arg source_mode "$source_mode" \
    --arg source_content_id "$source_content_id" \
    --argjson mode_change "$mode_change" \
    --argjson type_change "$type_change" \
    '{
      path:$path, tracked:$tracked, change_type:$change_type,
      mode:$mode, type:$type, content_id:$content_id,
      rename_from: (if $rename_from == "" then null else $rename_from end),
      source_mode: (if $source_mode == "" then null else $source_mode end),
      source_content_id: (if $source_content_id == "" then null else $source_content_id end),
      mode_change:$mode_change, type_change:$type_change
    }'
}

# collect_worktree — emit one JSON object per line for the complete worktree
# candidate (unsorted).
collect_worktree() {
  local -a fields=()
  mapfile -d '' fields < <(git -C "$REPO_ROOT" status --porcelain=v2 -z --untracked-files=all --renames)
  local i=0 n="${#fields[@]}" f rec
  while [ "$i" -lt "$n" ]; do
    f="${fields[$i]}"
    case "$f" in
      '1 '*)
        rec="${f#* * * * * * * * }"          # path (8 fixed fields)
        local head xy sub mH mI mW hH hI path headlen
        path="$rec"
        headlen=$(( ${#f} - ${#path} ))
        head="${f:0:headlen}"
        read -r _ xy sub mH mI mW hH hI <<<"$head"
        _entry_ordinary "$path" "$mH" "$mW" "$hH"
        i=$((i + 1))
        ;;
      '2 '*)
        rec="${f#* * * * * * * * * }"        # dest path (9 fixed fields)
        local head xy sub mH mI mW hH hI xs path headlen src
        path="$rec"
        headlen=$(( ${#f} - ${#path} ))
        head="${f:0:headlen}"
        read -r _ xy sub mH mI mW hH hI xs <<<"$head"
        src="${fields[$((i + 1))]}"
        _entry_rename "$path" "$src" "$mH" "$mW" "$hH"
        i=$((i + 2))
        ;;
      '? '*)
        _entry_untracked "${f#? }"
        i=$((i + 1))
        ;;
      'u '*)
        rec="${f#* * * * * * * * * * }"      # path (10 fixed fields)
        local head m1 m2 m3 mW path headlen
        path="$rec"
        headlen=$(( ${#f} - ${#path} ))
        head="${f:0:headlen}"
        read -r _ _ _ m1 m2 m3 mW _ <<<"$head"
        _entry_unmerged "$path" "$mW"
        i=$((i + 1))
        ;;
      '! '*) i=$((i + 1)) ;;
      *)     i=$((i + 1)) ;;
    esac
  done
}

_entry_ordinary() {
  local path="$1" mH="$2" mW="$3" hH="$4"
  local ct mode etype cid smode scid mc tc srcmode="$mH" srccid="$hH"
  [ "$mH" = "$ZERO_SHA" ] 2>/dev/null || true
  if [ "$mW" = "000000" ]; then
    ct=deleted; mode=000000; etype=deleted; cid=DELETED
    mc=false; tc=false
  else
    mode="$mW"; etype="$(mode_type "$mW")"
    cid="$(worktree_content_id "$path" "$mW")"
    if [ "$mH" = "000000" ]; then
      ct=added
    elif [ "$(mode_class "$mH")" != "$(mode_class "$mW")" ]; then
      ct=typechange
    else
      ct=modified
    fi
    if [ "$mH" != "000000" ] && [ "$mH" != "$mW" ]; then mc=true; else mc=false; fi
    if [ "$mH" != "000000" ] && [ "$(mode_class "$mH")" != "$(mode_class "$mW")" ]; then tc=true; else tc=false; fi
  fi
  smode="$mH"; [ "$smode" = "000000" ] && smode=""
  scid="$hH";  [ "$scid" = "$ZERO_SHA" ] && scid=""
  emit_entry "$path" true "$ct" "$mode" "$etype" "$cid" "" "$smode" "$scid" "$mc" "$tc"
}

_entry_rename() {
  local path="$1" src="$2" mH="$3" mW="$4" hH="$5"
  local mode etype cid mc tc smode scid
  mode="$mW"; etype="$(mode_type "$mW")"
  cid="$(worktree_content_id "$path" "$mW")"
  if [ "$mH" != "000000" ] && [ "$mH" != "$mW" ]; then mc=true; else mc=false; fi
  if [ "$mH" != "000000" ] && [ "$(mode_class "$mH")" != "$(mode_class "$mW")" ]; then tc=true; else tc=false; fi
  smode="$mH"; [ "$smode" = "000000" ] && smode=""
  scid="$hH";  [ "$scid" = "$ZERO_SHA" ] && scid=""
  emit_entry "$path" true renamed "$mode" "$etype" "$cid" "$src" "$smode" "$scid" "$mc" "$tc"
}

_entry_untracked() {
  local path="$1" abs="$REPO_ROOT/$1" mode etype cid
  if [ -L "$abs" ]; then
    mode=120000; etype=symlink
    cid="$(readlink -n -- "$abs" | git hash-object --stdin)"
  elif [ -d "$abs" ]; then
    return 0
  elif [ -x "$abs" ]; then
    mode=100755; etype=file; cid="$(git hash-object -- "$abs")"
  else
    mode=100644; etype=file; cid="$(git hash-object -- "$abs")"
  fi
  emit_entry "$path" false added "$mode" "$etype" "$cid" "" "" "" false false
}

_entry_unmerged() {
  local path="$1" mW="$2" abs="$REPO_ROOT/$1" mode etype cid
  mode="$mW"; etype="$(mode_type "$mW")"
  if [ -L "$abs" ]; then
    cid="$(readlink -n -- "$abs" | git hash-object --stdin)"
  elif [ -e "$abs" ]; then
    cid="$(git hash-object -- "$abs")"
  else
    cid=UNMERGED
  fi
  emit_entry "$path" true unmerged "$mode" "$etype" "$cid" "" "" "" false false
}

# collect_staged — one JSON object per line, index vs HEAD.
collect_staged() {
  local -a fields=()
  mapfile -d '' fields < <(git -C "$REPO_ROOT" diff --cached --raw -z --no-abbrev -M)
  local i=0 n="${#fields[@]}" f
  while [ "$i" -lt "$n" ]; do
    f="${fields[$i]}"
    case "$f" in
      :*)
        local omode nmode osha nsha status rest
        rest="${f#:}"
        read -r omode nmode osha nsha status <<<"$rest"
        case "$status" in
          R*|C*)
            local src dst
            src="${fields[$((i + 1))]}"
            dst="${fields[$((i + 2))]}"
            _staged_entry renamed "$dst" "$src" "$omode" "$nmode" "$osha" "$nsha"
            i=$((i + 3))
            ;;
          *)
            local path ct
            path="${fields[$((i + 1))]}"
            case "$status" in
              A) ct=added ;;
              D) ct=deleted ;;
              M) ct=modified ;;
              T) ct=typechange ;;
              U) ct=unmerged ;;
              *) ct=modified ;;
            esac
            _staged_entry "$ct" "$path" "" "$omode" "$nmode" "$osha" "$nsha"
            i=$((i + 2))
            ;;
        esac
        ;;
      *) i=$((i + 1)) ;;
    esac
  done
}

_staged_entry() {
  local ct="$1" path="$2" src="$3" omode="$4" nmode="$5" osha="$6" nsha="$7"
  local mode etype cid smode scid mc tc
  if [ "$ct" = deleted ] || [ "$nmode" = 000000 ]; then
    ct=deleted; mode=000000; etype=deleted; cid=DELETED
  else
    mode="$nmode"; etype="$(mode_type "$nmode")"; cid="$nsha"
  fi
  if [ "$omode" != "000000" ] && [ "$nmode" != "000000" ] && [ "$omode" != "$nmode" ]; then mc=true; else mc=false; fi
  if [ "$omode" != "000000" ] && [ "$nmode" != "000000" ] && [ "$(mode_class "$omode")" != "$(mode_class "$nmode")" ]; then tc=true; else tc=false; fi
  smode="$omode"; [ "$smode" = "000000" ] && smode=""
  scid="$osha";   [ "$scid" = "$ZERO_SHA" ] && scid=""
  emit_entry "$path" true "$ct" "$mode" "$etype" "$cid" "$src" "$smode" "$scid" "$mc" "$tc"
}

# --------------------------------------------------------------------------
# Fingerprint / manifest
# --------------------------------------------------------------------------

# entries_to_sorted_array — read one JSON object per line on stdin, print a
# compact sorted JSON array.
entries_to_sorted_array() {
  jq -sc 'sort_by(.path)'
}

fingerprint_of_array() {
  # canonical target-state projection only; source_* never participate
  jq -Sc 'map({change_type, mode, type, content_id, rename_from, tracked, path})' \
    | sha256sum | awk '{print "sha256:" $1}'
}

cmd_list()      { collect_worktree | entries_to_sorted_array; }
cmd_manifest() {
  local arr; arr="$(collect_worktree | entries_to_sorted_array)"
  local fp; fp="$(printf '%s' "$arr" | fingerprint_of_array)"
  jq -cn --argjson entries "$arr" --arg fp "$fp" '{fingerprint:$fp, entries:$entries}'
}
cmd_fingerprint() { collect_worktree | entries_to_sorted_array | fingerprint_of_array; }

cmd_staged_manifest() {
  local arr; arr="$(collect_staged | entries_to_sorted_array)"
  local fp; fp="$(printf '%s' "$arr" | fingerprint_of_array)"
  jq -cn --argjson entries "$arr" --arg fp "$fp" '{fingerprint:$fp, entries:$entries}'
}

# --------------------------------------------------------------------------
# Scope classification (separate from fingerprinting)
# --------------------------------------------------------------------------

SCOPE_ALLOWED=()
SCOPE_PROTECTED=()
SCOPE_STAGED=0

load_scope_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --allowed)   SCOPE_ALLOWED+=("${2:-}"); shift 2 ;;
      --protected) SCOPE_PROTECTED+=("${2:-}"); shift 2 ;;
      --staged)    SCOPE_STAGED=1; shift ;;
      --contract-file)
        local cf="${2:-}"; shift 2
        [ -f "$cf" ] || fail CANDIDATE_USAGE "contract file not found: $cf"
        mapfile -t SCOPE_ALLOWED   < <(jq -r '.allowed[]?' "$cf")
        mapfile -t SCOPE_PROTECTED < <(jq -r '.protected[]?' "$cf")
        ;;
      *) fail CANDIDATE_USAGE "unknown scope argument: $1" ;;
    esac
  done
  [ "${#SCOPE_ALLOWED[@]}" -gt 0 ]   || fail CANDIDATE_USAGE "scope needs at least one --allowed entry"
  [ "${#SCOPE_PROTECTED[@]}" -gt 0 ] || fail CANDIDATE_USAGE "scope needs at least one --protected entry"
}

# classify_side SIDE — print "" when SIDE is in scope, or "REASON|entry" when not.
# Candidate-path containment: the candidate is evaluated by its own repo-relative
# Git path. The final path component is NOT dereferenced (a candidate symlink is
# authorised by its own path). Only an ancestor-directory escape is rejected as
# CANDIDATE_OUTSIDE_REPO. ancestor_within_repo returns a status and never exits,
# so this is safe inside command substitution without `set -e`.
classify_side() {
  local side="$1" entry
  if ! ancestor_within_repo "$REPO_ROOT" "$side" >/dev/null 2>&1; then
    printf 'CANDIDATE_OUTSIDE_REPO|'
    return 0
  fi
  for entry in "${SCOPE_PROTECTED[@]}"; do
    if path_matches "$side" "$entry"; then printf 'CANDIDATE_PROTECTED|%s' "$entry"; return 0; fi
  done
  for entry in "${SCOPE_ALLOWED[@]}"; do
    if path_matches "$side" "$entry"; then printf ''; return 0; fi
  done
  printf 'CANDIDATE_OUT_OF_SCOPE|'
}

cmd_scope() {
  load_scope_args "$@"
  local list
  if [ "$SCOPE_STAGED" = 1 ]; then
    list="$(collect_staged | entries_to_sorted_array)"
  else
    list="$(collect_worktree | entries_to_sorted_array)"
  fi
  local violations='[]'
  local n; n="$(jq 'length' <<<"$list")"
  local idx path ct rf side reason r e
  for ((idx = 0; idx < n; idx++)); do
    path="$(jq -r ".[$idx].path" <<<"$list")"
    ct="$(jq -r ".[$idx].change_type" <<<"$list")"
    rf="$(jq -r ".[$idx].rename_from // \"\"" <<<"$list")"
    for side_kind in path rename_from; do
      if [ "$side_kind" = rename_from ]; then
        [ "$ct" = renamed ] || continue
        side="$rf"
      else
        side="$path"
      fi
      reason="$(classify_side "$side")"
      [ -n "$reason" ] || continue
      r="${reason%%|*}"; e="${reason#*|}"
      violations="$(jq -c --arg p "$side" --arg s "$side_kind" --arg r "$r" --arg e "$e" \
        '. + [{path:$p, side:$s, reason:$r, entry:(if $e=="" then null else $e end)}]' <<<"$violations")"
    done
  done
  if [ "$(jq 'length' <<<"$violations")" -eq 0 ]; then
    printf '{"result":"PASS","violations":[]}\n'
    return 0
  fi
  jq -cn --argjson v "$violations" '{result:"FAIL", violations:$v}'
  return 1
}

# --------------------------------------------------------------------------
# Staged comparison
# --------------------------------------------------------------------------

# Semantic target-state normalisation used for reviewed-vs-staged equality.
# A rename S->D is the same TARGET STATE as (S gone) + (D present with the
# destination mode/type/content), so both representations project to the same
# set. Content/mode/type comparison is preserved; raw rename info is kept as
# separate evidence.
readonly STAGED_NORM_JQ='
  def norm:
    [ .[] |
      if .change_type == "renamed" then
        ( {path: .rename_from, kind: "gone"} ),
        ( {path: .path, kind: "present", mode: .mode, type: .type, content_id: .content_id} )
      elif .change_type == "deleted" then
        {path: .path, kind: "gone"}
      elif .change_type == "unmerged" then
        {path: .path, kind: "unmerged"}
      else
        {path: .path, kind: "present", mode: .mode, type: .type, content_id: .content_id}
      end
    ] | sort_by(.path, .kind, (.mode // ""), (.type // ""), (.content_id // ""));
'

# nul_to_json_array — read NUL-delimited stdin, emit a JSON string array.
nul_to_json_array() {
  local -a a=()
  mapfile -d '' -t a
  local out='[]' x
  for x in "${a[@]}"; do
    [ -n "$x" ] || continue
    out="$(jq -c --arg v "$x" '. + [$v]' <<<"$out")"
  done
  printf '%s' "$out"
}

# mapfile_untracked — read porcelain v2 -z on stdin, emit JSON array of the
# untracked non-ignored paths.
mapfile_untracked() {
  local -a fields=()
  mapfile -d '' fields
  local out='[]' f
  for f in "${fields[@]}"; do
    case "$f" in
      '? '*) out="$(jq -c --arg p "${f#? }" '. + [$p]' <<<"$out")" ;;
    esac
  done
  printf '%s' "$out"
}

cmd_staged_compare() {
  local reviewed_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewed-manifest) reviewed_file="${2:-}"; shift 2 ;;
      *) fail CANDIDATE_USAGE "unknown staged-compare argument: $1" ;;
    esac
  done
  [ -n "$reviewed_file" ] && [ -f "$reviewed_file" ] ||
    fail CANDIDATE_USAGE "staged-compare requires --reviewed-manifest FILE"

  local reviewed staged staged_fp
  reviewed="$(jq -c 'if type=="object" and has("entries") then .entries else . end' "$reviewed_file")" ||
    fail CANDIDATE_STAGED_MANIFEST_INVALID "reviewed manifest is not valid JSON"
  staged="$(collect_staged | entries_to_sorted_array)"
  staged_fp="$(printf '%s' "$staged" | fingerprint_of_array)"

  # semantic (target-state) projections
  local nr ns
  nr="$(jq -c "$STAGED_NORM_JQ"' norm' <<<"$reviewed")"
  ns="$(jq -c "$STAGED_NORM_JQ"' norm' <<<"$staged")"

  local staged_matches_reviewed no_unexpected_staged nr_subset_ns
  staged_matches_reviewed=$([ "$nr" = "$ns" ] && echo true || echo false)
  no_unexpected_staged="$(jq -cn --argjson nr "$nr" --argjson ns "$ns" '($ns - $nr) | length == 0')"
  nr_subset_ns="$(jq -cn --argjson nr "$nr" --argjson ns "$ns" '($nr - $ns) | length == 0')"

  # reviewed target-state paths (destination for a rename; nothing for a delete)
  local rev_targets
  rev_targets="$(jq -c '[ .[] | select(.change_type != "deleted") | .path ]' <<<"$reviewed")"

  # reviewed target further modified in the worktree after staging (index vs worktree)
  local dirty
  dirty="$(git -C "$REPO_ROOT" diff --name-only -z | nul_to_json_array)"
  local no_reviewed_left_unstaged
  no_reviewed_left_unstaged="$(jq -cn --argjson subset "$nr_subset_ns" --argjson t "$rev_targets" --argjson d "$dirty" \
    '$subset and (([ $t[] | select(. as $p | $d | index($p)) ] | length) == 0)')"

  # unexpected non-ignored untracked files not among the reviewed target paths
  local untracked no_unexpected_untracked
  untracked="$(git -C "$REPO_ROOT" status --porcelain=v2 -z --untracked-files=all | mapfile_untracked)"
  no_unexpected_untracked="$(jq -cn --argjson u "$untracked" --argjson t "$rev_targets" \
    '([ $u[] | select(. as $p | ($t | index($p)) | not) ] | length) == 0')"

  # every reviewed rename S->D is represented (as a staged rename OR an equivalent
  # source-delete + destination-add) with the reviewed destination mode/type/content
  local rename_semantics_preserved
  rename_semantics_preserved="$(jq -cn --argjson r "$reviewed" --argjson ns "$ns" '
    [ $r[] | select(.change_type == "renamed") ] as $rr
    | ( $rr | all(. as $e
        | ($ns | any(.kind == "gone" and .path == $e.rename_from))
          and ($ns | any(.kind == "present" and .path == $e.path
                          and .mode == $e.mode and .type == $e.type
                          and .content_id == $e.content_id)) ) )
  ')"

  local whitespace_clean="true"
  git -C "$REPO_ROOT" diff --cached --check >/dev/null 2>&1 || whitespace_clean="false"

  local reviewed_renames staged_renames
  reviewed_renames="$(jq -c '[ .[] | select(.change_type=="renamed") | {rename_from, path} ]' <<<"$reviewed")"
  staged_renames="$(jq -c '[ .[] | select(.change_type=="renamed") | {rename_from, path} ]' <<<"$staged")"

  local ok
  ok=$([ "$staged_matches_reviewed" = true ] && [ "$no_unexpected_staged" = true ] && \
       [ "$no_reviewed_left_unstaged" = true ] && [ "$no_unexpected_untracked" = true ] && \
       [ "$rename_semantics_preserved" = true ] && [ "$whitespace_clean" = true ] && echo true || echo false)

  jq -cn \
    --argjson staged_matches_reviewed "$staged_matches_reviewed" \
    --argjson no_unexpected_staged "$no_unexpected_staged" \
    --argjson no_reviewed_left_unstaged "$no_reviewed_left_unstaged" \
    --argjson no_unexpected_untracked "$no_unexpected_untracked" \
    --argjson rename_semantics_preserved "$rename_semantics_preserved" \
    --argjson whitespace_clean "$whitespace_clean" \
    --arg staged_fingerprint "$staged_fp" \
    --argjson reviewed_renames "$reviewed_renames" \
    --argjson staged_renames "$staged_renames" \
    --argjson ok "$ok" \
    '{staged_matches_reviewed:$staged_matches_reviewed,
      no_unexpected_staged:$no_unexpected_staged,
      no_reviewed_left_unstaged:$no_reviewed_left_unstaged,
      no_unexpected_untracked:$no_unexpected_untracked,
      rename_semantics_preserved:$rename_semantics_preserved,
      whitespace_clean:$whitespace_clean,
      staged_fingerprint:$staged_fingerprint,
      reviewed_renames:$reviewed_renames,
      staged_renames:$staged_renames,
      ok:$ok}'
  [ "$ok" = true ]
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: candidate.sh [--repo-root DIR] <command> [args]
  list | manifest | fingerprint | staged-manifest
  scope [--staged] --allowed P ... --protected P ... | scope [--staged] --contract-file F
  staged-compare --reviewed-manifest F
EOF
  exit 2
}

main() {
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root) REPO_DIR="${2:-}"; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  if [ "${#rest[@]}" -gt 0 ]; then set -- "${rest[@]}"; else set --; fi
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift || true
  resolve_root

  case "$cmd" in
    list)            cmd_list ;;
    manifest)        cmd_manifest ;;
    fingerprint)     cmd_fingerprint ;;
    staged-manifest) cmd_staged_manifest ;;
    scope)           cmd_scope "$@" ;;
    staged-compare)  cmd_staged_compare "$@" ;;
    -h|--help)       usage ;;
    *)               usage ;;
  esac
}

main "$@"
