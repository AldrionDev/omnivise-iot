#!/usr/bin/env bash
# contract_test.sh — issue-contract.sh

suite "issue-contract"

C() { bash "$CONTRACT_SH" "$@"; }

# --- valid contracts -------------------------------------------------------

assert_ok        "canonical valid contract validates"        C validate "$(fx_contract valid)"
assert_ok        "valid contract at heading level 4"          C validate "$(fx_contract deep-headings '####')"
assert_ok        "valid contract at heading level 6"          C validate "$(fx_contract deep-headings '######')"
assert_ok        "path marker as label line"                  C validate "$(fx_contract label-marker)"
assert_ok        "disjoint Allowed/Protected contract"        C validate "$(fx_contract disjoint)"
assert_ok        "Technical Notes = None (no path contract)"  C validate "$(fx_contract tn-none)"

run_capture C sections "$(fx_contract valid)"
assert_eq        "sections lists all 9 canonical names" \
                 "problem / context
goal
scope
out of scope
acceptance criteria
verification
definition of done
human gates / maintainer decisions
technical notes / constraints" "$OUT"

# --- fenced-code headings are ignored ------------------------------------

assert_ok        "backtick-fenced canonical heading is ignored" C validate "$(fx_contract fenced-backtick-heading)"
assert_ok        "tilde-fenced canonical heading is ignored"    C validate "$(fx_contract fenced-tilde-heading)"

# --- structural failures -------------------------------------------------

assert_fail_code "missing required section"      ISSUE_CONTRACT_MISSING_SECTION   C validate "$(fx_contract missing-goal)"
assert_fail_code "duplicate required section"    ISSUE_CONTRACT_DUPLICATE_SECTION C validate "$(fx_contract duplicate-goal)"
assert_fail_code "out-of-order sections"         ISSUE_CONTRACT_SECTION_ORDER     C validate "$(fx_contract out-of-order)"
assert_fail_code "empty required section"        ISSUE_CONTRACT_EMPTY_SECTION     C validate "$(fx_contract empty-goal)"
assert_fail_code "comment-only section is empty" ISSUE_CONTRACT_EMPTY_SECTION     C validate "$(fx_contract comment-goal)"
assert_fail_code "Acceptance Criteria needs a checkbox" ISSUE_CONTRACT_AC_NO_CHECKBOX  C validate "$(fx_contract ac-no-checkbox)"
assert_fail_code "Definition of Done needs a checkbox"  ISSUE_CONTRACT_DOD_NO_CHECKBOX C validate "$(fx_contract dod-no-checkbox)"

# --- Human Gates -------------------------------------------------------------

run_capture C human-gates "$(fx_contract gates-none)"
assert_contains  "Human Gates None -> status none"       "$OUT" '"status":"none"'
run_capture C human-gates "$(fx_contract gates-resolved)"
assert_contains  "resolved Human Gate -> status resolved" "$OUT" '"status":"resolved"'
run_capture C human-gates "$(fx_contract gates-unresolved)"
assert_contains  "unresolved Human Gate -> status unresolved" "$OUT" '"status":"unresolved"'
assert_fail_code "malformed Human Gate prose rejected"  ISSUE_CONTRACT_HUMAN_GATE_MALFORMED C validate "$(fx_contract gates-malformed)"

# --- path grammar ----------------------------------------------------------

run_capture C paths "$(fx_contract valid)"
assert_contains  "paths emits normalized allowed list"  "$OUT" '".claude/scripts/**"'
assert_contains  "paths emits normalized protected list" "$OUT" '"backend/**"'
assert_json      "paths output is valid JSON"           "$OUT"

assert_fail_code "absolute path rejected"   ISSUE_PATH_CONTRACT_INVALID C validate "$(fx_contract path-absolute)"
assert_fail_code "'..' segment rejected"    ISSUE_PATH_CONTRACT_INVALID C validate "$(fx_contract path-dotdot)"
assert_fail_code "leading '~' rejected"     ISSUE_PATH_CONTRACT_INVALID C validate "$(fx_contract path-tilde)"
assert_fail_code "unsupported wildcard rejected"       ISSUE_PATH_CONTRACT_INVALID C validate "$(fx_contract path-wildcard)"
assert_fail_code "shell metacharacter path rejected"  ISSUE_PATH_CONTRACT_INVALID C validate "$(fx_contract path-metachar)"

# --- conflict semantics --------------------------------------------------

assert_fail_code "literal == literal conflict"   ISSUE_PATH_CONTRACT_CONFLICT C validate "$(fx_contract conflict-literal)"
assert_fail_code "literal within prefix conflict" ISSUE_PATH_CONTRACT_CONFLICT C validate "$(fx_contract conflict-literal-prefix)"
assert_fail_code "prefix over literal conflict"   ISSUE_PATH_CONTRACT_CONFLICT C validate "$(fx_contract conflict-prefix-literal)"
assert_fail_code "prefix == prefix conflict"      ISSUE_PATH_CONTRACT_CONFLICT C validate "$(fx_contract conflict-prefix-prefix)"

# --- contract hash -------------------------------------------------------

body_lf="$(fx_contract valid)"
h_lf="$(C hash "$body_lf")"
body_crlf="$(mktemp "$TEST_TMP_ROOT/contract.XXXXXX.md")"
sed 's/$/\r/' "$body_lf" > "$body_crlf"
printf '\r\n\r\n' >> "$body_crlf"     # add trailing blank CRLF lines
h_crlf="$(C hash "$body_crlf")"
assert_eq        "contract hash stable across CRLF + trailing blanks" "$h_lf" "$h_crlf"

body_changed="$(mktemp "$TEST_TMP_ROOT/contract.XXXXXX.md")"
sed 's/small deterministic core/SMALL DETERMINISTIC CORE/' "$body_lf" > "$body_changed"
h_changed="$(C hash "$body_changed")"
assert_ne        "contract hash changes on content change" "$h_lf" "$h_changed"

# --- regression: authoritative #15-shaped contract (checked-in static fixture) --
# Deterministic: no `gh`, no network, no GitHub auth. Same assertion count always.

issue15="$SCRIPTS_DIR/../tests/fixtures/issue15-contract.md"
assert_file_exists "static issue #15 contract fixture is checked in"    "$issue15"
assert_ok          "issue #15-shaped contract validates"                C validate "$issue15"
run_capture C paths "$issue15"
assert_contains    "issue #15 Allowed Changed Paths parsed"             "$OUT" '".claude/scripts/**"'
assert_contains    "issue #15 Allowed tests path parsed"                "$OUT" '".claude/tests/**"'
assert_contains    "issue #15 Protected mongo-init.js parsed"           "$OUT" '"mongo-init.js"'
assert_contains    "issue #15 Protected mongo-replica-init.js parsed"   "$OUT" '"mongo-replica-init.js"'
run_capture C human-gates "$issue15"
assert_contains    "issue #15 Human Gates -> status none"               "$OUT" '"status":"none"'
run_capture C sections "$issue15"
assert_eq          "issue #15 fixture reports exactly the 9 canonical sections in order" \
  "problem / context
goal
scope
out of scope
acceptance criteria
verification
definition of done
human gates / maintainer decisions
technical notes / constraints" "$OUT"
# fenced-code `### Allowed Changed Paths` markers in Scope must NOT be treated as
# the Technical-Notes path contract:
run_capture C paths "$issue15"
assert_not_contains "fenced 'path/to/file' example not parsed as a path entry"   "$OUT" 'path/to/file'

# --- Blocking finding 4: contradictory Human Gates None fails closed -----

assert_ok        "Human Gates plain None -> valid" C validate "$(fx_contract gates-none)"
run_capture C human-gates "$(fx_contract gates-none)"
assert_contains  "plain None -> status none" "$OUT" '"status":"none"'

assert_ok        "Human Gates None + explanatory prose -> valid" C validate "$(fx_contract gates-none-prose)"
run_capture C human-gates "$(fx_contract gates-none-prose)"
assert_contains  "None + prose -> status none" "$OUT" '"status":"none"'

assert_fail_code "None + unchecked box -> malformed"  ISSUE_CONTRACT_HUMAN_GATE_MALFORMED C validate "$(fx_contract gates-none-unchecked)"
assert_fail_code "None + checked box -> malformed"    ISSUE_CONTRACT_HUMAN_GATE_MALFORMED C validate "$(fx_contract gates-none-checked)"
assert_fail_code "None + PENDING: marker -> malformed" ISSUE_CONTRACT_HUMAN_GATE_MALFORMED C validate "$(fx_contract gates-none-pending)"
assert_fail_code "None + UNRESOLVED: marker -> malformed" ISSUE_CONTRACT_HUMAN_GATE_MALFORMED C validate "$(fx_contract gates-none-unresolved-marker)"

# --- Blocking finding 5: fenced code is real section content ------------

assert_ok        "section with only a non-empty fenced block -> non-empty (valid)" \
  C validate "$(fx_contract verify-fenced-only)"
assert_ok        "fenced block containing a canonical heading -> section still non-empty, no dup" \
  C validate "$(fx_contract verify-fenced-heading-only)"
run_capture C sections "$(fx_contract verify-fenced-heading-only)"
assert_eq        "fenced 'Goal' inside Verification does not create/duplicate a section (still 9)" \
  "9" "$(printf '%s\n' "$OUT" | grep -c .)"
# deterministic result for an empty fence: no actual content -> empty section
assert_fail_code "section whose only fence is empty -> EMPTY_SECTION" \
  ISSUE_CONTRACT_EMPTY_SECTION C validate "$(fx_contract verify-empty-fence)"
