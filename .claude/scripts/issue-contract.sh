#!/usr/bin/env bash
#
# issue-contract.sh — deterministic validation of the repository's canonical
# 9-section engineering issue contract, plus the optional path contract inside
# `Technical Notes / Constraints`.
#
#   issue-contract.sh validate     <body>   # exit 0 + "ISSUE_CONTRACT_VALID"
#   issue-contract.sh sections     <body>   # canonical headings, in file order
#   issue-contract.sh paths        <body>   # {"allowed":[...],"protected":[...]}
#   issue-contract.sh human-gates  <body>   # {"status":..., "items":[...]}
#   issue-contract.sh hash         <body>   # sha256 of the normalised body
#   issue-contract.sh contract     <body>   # sections + paths + human_gates + hash
#
# <body> is a file path, or `-` to read the issue body from standard input.
#
# The parser validates contract STRUCTURE only. Repository-aware semantic
# correctness is a future planner responsibility. Issue/model content is treated
# strictly as data: no eval, no command strings, no unsafe path interpolation.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

require_cmd jq ISSUE_CONTRACT_TOOLING_MISSING
require_cmd sha256sum ISSUE_CONTRACT_TOOLING_MISSING
require_cmd awk ISSUE_CONTRACT_TOOLING_MISSING

readonly CANONICAL='problem / context
goal
scope
out of scope
acceptance criteria
verification
definition of done
human gates / maintainer decisions
technical notes / constraints'

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

STDIN_DIR=""
cleanup_stdin() { [ -n "$STDIN_DIR" ] && rm -rf "$STDIN_DIR" 2>/dev/null || true; STDIN_DIR=""; }
trap cleanup_stdin EXIT INT TERM HUP

BODY_FILE=""
resolve_body() {
  local arg="${1:-}"
  [ -n "$arg" ] || fail ISSUE_CONTRACT_INVALID "an issue body (file path or '-') is required"
  if [ "$arg" != "-" ]; then
    [ -f "$arg" ] || fail ISSUE_CONTRACT_INVALID "issue body file not found: $arg"
    BODY_FILE="$arg"
    return 0
  fi
  local old_umask; old_umask="$(umask)"
  umask 077
  STDIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue-contract.XXXXXX")" ||
    fail ISSUE_CONTRACT_INVALID "could not buffer the issue body"
  BODY_FILE="$STDIN_DIR/body.md"
  cat >"$BODY_FILE"
  umask "$old_umask"
  [ -s "$BODY_FILE" ] || fail ISSUE_CONTRACT_INVALID "the issue body read from stdin is empty"
}

# ---------------------------------------------------------------------------
# Markdown scanning (fenced-code aware). Ported and trimmed from the sibling
# local-jenkins-platform issue-contract.sh AWK fence tracker.
# ---------------------------------------------------------------------------

readonly AWK_LIB='
function fence_scan(line,   ch, run, tail) {
  if (line !~ /^[ \t]*(`{3,}|~{3,})/) return 0
  sub(/^[ \t]*/, "", line)
  ch = substr(line, 1, 1)
  run = 0
  while (substr(line, run + 1, 1) == ch) run++
  if (!in_fence) { in_fence = 1; fence_char = ch; fence_run = run; return 1 }
  if (ch == fence_char && run >= fence_run) {
    tail = substr(line, run + 1)
    if (tail ~ /^[ \t]*$/) { in_fence = 0; return 1 }
  }
  return 1
}
function norm(s) {
  s = tolower(s)
  gsub(/[`*_]/, "", s)
  gsub(/[ \t]+/, " ", s)
  sub(/^ /, "", s); sub(/ $/, "", s); sub(/:$/, "", s)
  return s
}
function heading_level(line,   n) {
  if (line !~ /^#{2,6}[ \t]+/) return 0
  match(line, /^#+/); n = RLENGTH
  if (n < 2 || n > 6) return 0
  return n
}
function heading_text(line,   t) {
  t = line; sub(/^#+[ \t]+/, "", t); return t
}
'

list_headings() {
  awk "$AWK_LIB"'
    { if (fence_scan($0)) next }
    in_fence { next }
    {
      lvl = heading_level($0)
      if (lvl) printf "%d\t%s\n", lvl, norm(heading_text($0))
    }
  ' "$1"
}

# section_body FILE WANTED WANT_FENCES(1|0)
section_body() {
  awk -v wanted="$2" -v wf="$3" "$AWK_LIB"'
    {
      if (fence_scan($0)) { if (collecting && wf == "1") print; next }
      if (in_fence)       { if (collecting && wf == "1") print; next }
    }
    {
      lvl = heading_level($0)
      if (lvl) {
        nt = norm(heading_text($0))
        if (collecting && lvl <= clvl) collecting = 0
        if (!collecting && nt == wanted) { collecting = 1; clvl = lvl; next }
        if (collecting) print
        next
      }
      if (collecting) print
    }
  ' "$1"
}

strip_html_comments() {
  awk '
    {
      line = $0
      while (1) {
        if (in_c) {
          k = index(line, "-->")
          if (k == 0) { line = ""; break }
          line = substr(line, k + 3); in_c = 0
        } else {
          k = index(line, "<!--")
          if (k == 0) break
          pre = substr(line, 1, k - 1)
          rest = substr(line, k + 4)
          j = index(rest, "-->")
          if (j == 0) { line = pre; in_c = 1; break }
          line = pre substr(rest, j + 3)
        }
      }
      print line
    }
  '
}

# section_content_for_empty_check FILE HEADING — emit the section body with the
# fenced-code DELIMITER lines removed but the fenced CONTENT lines kept, and HTML
# comments stripped. A fenced code block is real section content; only its ``` /
# ~~~ delimiter lines are non-content. The heading parser still ignores
# canonical-looking headings inside fences (unchanged).
section_content_for_empty_check() {
  section_body "$1" "$2" 1 | awk "$AWK_LIB"'
    { if (fence_scan($0)) next }
    { print }
  ' | strip_html_comments
}

section_has_content() {
  local body
  body="$(section_content_for_empty_check "$1" "$2")"
  [ -n "${body//[[:space:]]/}" ]
}

section_has_checkbox() {
  local body
  body="$(section_body "$1" "$2" 0)"
  grep -Eq '^[[:space:]]*[-*+][[:space:]]+\[[ xX]\]([[:space:]]|$)' <<<"$body"
}

emit_sections() {
  local -a canon=(); mapfile -t canon < <(printf '%s\n' "$CANONICAL")
  local -A want=(); local c h
  for c in "${canon[@]}"; do want["$c"]=1; done
  while IFS= read -r h; do
    if [ -n "${want[$h]:-}" ]; then printf '%s\n' "$h"; fi
  done < <(list_headings "$1" | cut -f2-)
}

# ---------------------------------------------------------------------------
# Path contract
# ---------------------------------------------------------------------------

marker_present() {
  local tn; tn="$(section_body "$1" "technical notes / constraints" 0)"
  awk -v marker="$2" "$AWK_LIB"'
    { if (fence_scan($0)) next }
    in_fence { next }
    {
      lvl = heading_level($0)
      if (lvl) { if (norm(heading_text($0)) == marker) { found = 1; exit } ; next }
      lab = $0; sub(/^[ \t]+/, "", lab); sub(/[ \t]+$/, "", lab)
      ln = tolower(lab); sub(/:$/, "", ln); gsub(/[ \t]+/, " ", ln)
      if (ln == marker) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$tn"
}

extract_path_block() {
  local tn; tn="$(section_body "$1" "technical notes / constraints" 0)"
  awk -v marker="$2" "$AWK_LIB"'
    {
      if (fence_scan($0)) next
      if (in_fence) {
        if (!collecting) next
        line = $0
        if (line ~ /^[ \t]*#/) next
        if (line ~ /^[ \t]*$/) next
        gsub(/`/, "", line); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
        if (length(line)) { print line; collected++ }
        next
      }
      lvl = heading_level($0)
      if (lvl) {
        if (!collecting) { if (norm(heading_text($0)) == marker) { collecting = 1; collected = 0 } ; next }
        exit
      }
      if (!collecting) {
        lab = $0; sub(/^[ \t]+/, "", lab); sub(/[ \t]+$/, "", lab)
        ln = tolower(lab); sub(/:$/, "", ln); gsub(/[ \t]+/, " ", ln)
        if (ln == marker) { collecting = 1; collected = 0 }
        next
      }
      if ($0 ~ /^[ \t]*$/) next
      if ($0 ~ /^[ \t]*[-*+][ \t]+/) {
        line = $0
        sub(/^[ \t]*[-*+][ \t]+/, "", line)
        gsub(/`/, "", line); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
        if (length(line)) { print line; collected++ }
        next
      }
      if (collected > 0) exit
    }
  ' <<<"$tn"
}

validate_path_entry() {
  local e="$1" core
  e="${e#./}"
  case "$e" in
    ''|'.'|'./'|'**'|'/**') fail ISSUE_PATH_CONTRACT_INVALID "invalid path entry: '$1'" ;;
    /*)   fail ISSUE_PATH_CONTRACT_INVALID "absolute path in contract: $1" ;;
    '~'*) fail ISSUE_PATH_CONTRACT_INVALID "home-relative path in contract: $1" ;;
  esac
  core="$e"
  case "$e" in
    */'**') core="${e%'/**'}" ;;
    *'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'!'*)
      fail ISSUE_PATH_CONTRACT_INVALID "unsupported wildcard/glob syntax in contract: $1" ;;
  esac
  case "/$core/" in
    *'/../'*|*'/./'*) fail ISSUE_PATH_CONTRACT_INVALID "path traversal segment in contract: $1" ;;
  esac
  [[ "$core" =~ ^[A-Za-z0-9._+@-]+(/[A-Za-z0-9._+@-]+)*$ ]] ||
    fail ISSUE_PATH_CONTRACT_INVALID "unsupported path syntax in contract: $1"
  printf '%s' "$e"
}

ALLOWED=()
PROTECTED=()

parse_paths() {
  local file="$1" a_present=0 p_present=0 i a q ak ac qk qc
  ALLOWED=(); PROTECTED=()
  marker_present "$file" "allowed changed paths" && a_present=1 || true
  marker_present "$file" "protected paths" && p_present=1 || true

  if [ "$a_present" -eq 0 ] && [ "$p_present" -eq 0 ]; then
    return 0
  fi
  { [ "$a_present" -eq 1 ] && [ "$p_present" -eq 1 ]; } ||
    fail ISSUE_PATH_CONTRACT_INVALID "Allowed Changed Paths and Protected Paths must both be present"

  mapfile -t ALLOWED < <(extract_path_block "$file" "allowed changed paths")
  mapfile -t PROTECTED < <(extract_path_block "$file" "protected paths")
  [ "${#ALLOWED[@]}" -gt 0 ]   || fail ISSUE_PATH_CONTRACT_INVALID "Allowed Changed Paths lists no entries"
  [ "${#PROTECTED[@]}" -gt 0 ] || fail ISSUE_PATH_CONTRACT_INVALID "Protected Paths lists no entries"

  for i in "${!ALLOWED[@]}";   do ALLOWED[$i]="$(validate_path_entry "${ALLOWED[$i]}")"; done
  for i in "${!PROTECTED[@]}"; do PROTECTED[$i]="$(validate_path_entry "${PROTECTED[$i]}")"; done

  local clash
  if clash="$(find_path_conflict \
      "$(printf '%s\n' "${ALLOWED[@]}")" \
      "$(printf '%s\n' "${PROTECTED[@]}")")"; then
    fail ISSUE_PATH_CONTRACT_CONFLICT "Allowed '${clash%%|*}' intersects Protected '${clash##*|}'"
  fi
}

emit_paths_json() {
  local a p
  a="$(printf '%s\n' "${ALLOWED[@]+"${ALLOWED[@]}"}" | json_array_from_lines)"
  p="$(printf '%s\n' "${PROTECTED[@]+"${PROTECTED[@]}"}" | json_array_from_lines)"
  jq -cn --argjson allowed "$a" --argjson protected "$p" '{allowed: $allowed, protected: $protected}'
}

# ---------------------------------------------------------------------------
# Human Gates
# ---------------------------------------------------------------------------

parse_human_gates() {
  local file="$1" body first lc
  body="$(section_body "$file" "human gates / maintainer decisions" 0 | strip_html_comments)"
  first="$(grep -m1 -v '^[[:space:]]*$' <<<"$body" || true)"
  lc="$(printf '%s' "$first" \
        | sed -e 's/^[[:space:]]*[-*+][[:space:]]*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    none|none.|none:)
      # A canonical None may still be followed by explanatory prose, but any
      # subsequent gate marker is contradictory and makes the section malformed.
      if grep -Eq '\[[ xX]\]|(^|[[:space:]])(RESOLVED|UNRESOLVED|PENDING):' <<<"$body"; then
        fail ISSUE_CONTRACT_HUMAN_GATE_MALFORMED \
          "Human Gates declares None but also contains gate marker(s)"
      fi
      printf '{"status":"none","items":[]}'
      return 0
      ;;
  esac

  local -a items_state=() items_text=()
  local line txt state
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    txt="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    state=""
    case "$txt" in
      *'[x]'*|*'[X]'*)                     state=resolved ;;
      *'[ ]'*)                             state=unresolved ;;
      [-*+][[:space:]]*RESOLVED:*|RESOLVED:*) state=resolved ;;
      [-*+][[:space:]]*UNRESOLVED:*|UNRESOLVED:*|[-*+][[:space:]]*PENDING:*|PENDING:*) state=unresolved ;;
      *)
        fail ISSUE_CONTRACT_HUMAN_GATE_MALFORMED "unclassifiable Human Gate line: $txt"
        ;;
    esac
    items_state+=("$state")
    items_text+=("$txt")
  done < <(printf '%s\n' "$body")

  [ "${#items_state[@]}" -gt 0 ] ||
    fail ISSUE_CONTRACT_HUMAN_GATE_MALFORMED "Human Gates section describes neither None nor any gate"

  local status=resolved i
  for i in "${!items_state[@]}"; do
    [ "${items_state[$i]}" = unresolved ] && status=unresolved
  done

  local arr='[]' t s
  for i in "${!items_state[@]}"; do
    t="${items_text[$i]}"; s="${items_state[$i]}"
    arr="$(jq -c --arg s "$s" --arg t "$t" '. + [{state:$s,text:$t}]' <<<"$arr")"
  done
  jq -cn --arg status "$status" --argjson items "$arr" '{status:$status, items:$items}'
}

# ---------------------------------------------------------------------------
# Contract hash
# ---------------------------------------------------------------------------

contract_hash() {
  sed 's/\r$//' "$1" \
    | awk '{ l[NR] = $0 } END { last = NR; while (last > 0 && l[last] ~ /^[ \t]*$/) last--; for (i = 1; i <= last; i++) print l[i] }' \
    | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Structure validation
# ---------------------------------------------------------------------------

validate_structure() {
  local file="$1"

  [ -n "$(list_headings "$file")" ] ||
    fail ISSUE_CONTRACT_UNSUPPORTED_FORMAT "no ATX headings (levels 2-6) outside fenced code blocks"

  local -a canon=() found=() seq=()
  mapfile -t canon < <(printf '%s\n' "$CANONICAL")
  mapfile -t found < <(list_headings "$file" | cut -f2-)

  local -A want=()
  local c h n
  for c in "${canon[@]}"; do want["$c"]=1; done
  for h in "${found[@]}"; do [ -n "${want[$h]:-}" ] && seq+=("$h"); done

  local -a missing=() dup=()
  for c in "${canon[@]}"; do
    n=0
    for h in "${seq[@]}"; do [ "$h" = "$c" ] && n=$((n + 1)); done
    [ "$n" -ge 1 ] || missing+=("$c")
    [ "$n" -le 1 ] || dup+=("$c")
  done
  [ "${#missing[@]}" -eq 0 ] ||
    fail ISSUE_CONTRACT_MISSING_SECTION "missing canonical section(s): ${missing[*]}"
  [ "${#dup[@]}" -eq 0 ] ||
    fail ISSUE_CONTRACT_DUPLICATE_SECTION "duplicate canonical section(s): ${dup[*]}"

  [ "$(printf '%s\n' "${seq[@]}")" = "$(printf '%s\n' "${canon[@]}")" ] ||
    fail ISSUE_CONTRACT_SECTION_ORDER "canonical sections are not in contract order"

  for c in "${canon[@]}"; do
    section_has_content "$file" "$c" ||
      fail ISSUE_CONTRACT_EMPTY_SECTION "canonical section has no meaningful content: $c"
  done

  section_has_checkbox "$file" "acceptance criteria" ||
    fail ISSUE_CONTRACT_AC_NO_CHECKBOX "Acceptance Criteria has no Markdown checkbox"
  section_has_checkbox "$file" "definition of done" ||
    fail ISSUE_CONTRACT_DOD_NO_CHECKBOX "Definition of Done has no Markdown checkbox"

  parse_human_gates "$file" >/dev/null
  parse_paths "$file"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: issue-contract.sh {validate|sections|paths|human-gates|hash|contract} <issue-body|->
EOF
  exit 2
}

main() {
  local cmd="${1:-}" arg="${2:-}"
  case "$cmd" in
    validate)
      resolve_body "$arg"; validate_structure "$BODY_FILE"; printf 'ISSUE_CONTRACT_VALID\n' ;;
    sections)
      resolve_body "$arg"; emit_sections "$BODY_FILE" ;;
    paths)
      resolve_body "$arg"; parse_paths "$BODY_FILE"; emit_paths_json ;;
    human-gates)
      resolve_body "$arg"; parse_human_gates "$BODY_FILE" ;;
    hash)
      resolve_body "$arg"; contract_hash "$BODY_FILE" ;;
    contract)
      resolve_body "$arg"
      validate_structure "$BODY_FILE"
      local sections_json paths_json gates_json h
      sections_json="$(emit_sections "$BODY_FILE" | json_array_from_lines)"
      paths_json="$(emit_paths_json)"
      gates_json="$(parse_human_gates "$BODY_FILE")"
      h="$(contract_hash "$BODY_FILE")"
      jq -cn \
        --argjson sections "$sections_json" \
        --argjson paths "$paths_json" \
        --argjson human_gates "$gates_json" \
        --arg hash "$h" \
        '{sections:$sections, allowed:$paths.allowed, protected:$paths.protected, human_gates:$human_gates, hash:$hash}'
      ;;
    ''|-h|--help) usage ;;
    *) usage ;;
  esac
}

main "$@"
