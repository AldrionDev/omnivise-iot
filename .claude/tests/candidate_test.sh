#!/usr/bin/env bash
# candidate_test.sh — candidate.sh

suite "candidate"

CA() { bash "$CANDIDATE_SH" --repo-root "$1" "${@:2}"; }
# ent JSON PATH .field  -> value of .field for the entry whose .path == PATH
ent() { jq -r --arg p "$2" '.[] | select(.path==$p)'"$3" <<<"$1"; }

# --- change types -----------------------------------------------------

R="$(fx_repo_new)"
printf 'one\ntwo\n' > "$R/mod.txt"
printf 'del\n'       > "$R/del.txt"
printf 'a\nb\nc\nd\n' > "$R/ren.txt"
printf 'x\n'         > "$R/exe.txt"
printf 'build/\n'   > "$R/.gitignore"
fx_commit "$R" seed
printf 'one\nTWO\n' > "$R/mod.txt"
git -C "$R" rm -q del.txt
git -C "$R" mv ren.txt renamed.txt
chmod +x "$R/exe.txt"
printf 'fresh\n' > "$R/new.txt"
mkdir -p "$R/build"; printf 'junk\n' > "$R/build/out.o"

L="$(CA "$R" list)"
assert_eq "tracked modification -> modified"  "modified" "$(ent "$L" mod.txt .change_type)"
assert_eq "tracked deletion -> deleted"       "deleted"  "$(ent "$L" del.txt .change_type)"
assert_eq "deletion mode canonical 000000"    "000000"   "$(ent "$L" del.txt .mode)"
assert_eq "deletion content_id canonical"     "DELETED"  "$(ent "$L" del.txt .content_id)"
assert_eq "tracked rename -> renamed"         "renamed"  "$(ent "$L" renamed.txt .change_type)"
assert_eq "rename records rename_from"        "ren.txt"  "$(ent "$L" renamed.txt .rename_from)"
assert_eq "no phantom deletion for rename src" ""        "$(ent "$L" ren.txt .change_type)"
assert_eq "untracked non-ignored file present" "added"   "$(ent "$L" new.txt .change_type)"
assert_eq "executable bit flip -> mode 100755" "100755"  "$(ent "$L" exe.txt .mode)"
assert_eq "executable bit flip -> mode_change" "true"    "$(ent "$L" exe.txt .mode_change)"
assert_eq "ignored build artifact excluded"    ""        "$(ent "$L" build/out.o .change_type)"

# --- NUL-safe filenames ---------------------------------------------

RN="$(fx_repo_new)"
printf 'x\n' > "$RN/plain space.txt"
printf 'x\n' > "$RN/-leading-dash.txt"
printf 'x\n' > "$RN/$(printf 'tab\there').txt" 2>/dev/null || true
LN="$(CA "$RN" list)"
assert_eq "filename with space handled"      "added" "$(ent "$LN" 'plain space.txt' .change_type)"
assert_eq "leading-dash filename handled"    "added" "$(ent "$LN" '-leading-dash.txt' .change_type)"
assert_json "list output is valid JSON"      "$LN"

# --- fingerprint semantics ---------------------------------------

RF="$(fx_repo_new)"
printf 'content\n' > "$RF/f.txt"
fp0="$(CA "$RF" fingerprint)"
fp0b="$(CA "$RF" fingerprint)"
assert_eq "fingerprint stable on unchanged tree" "$fp0" "$fp0b"
touch -d '2000-01-01' "$RF/f.txt" 2>/dev/null || touch "$RF/f.txt"
assert_eq "fingerprint ignores mtime-only change" "$fp0" "$(CA "$RF" fingerprint)"
printf 'content\nmore\n' > "$RF/f.txt"
fp1="$(CA "$RF" fingerprint)"
assert_ne "fingerprint changes after content edit" "$fp0" "$fp1"
git -C "$RF" add -A >/dev/null; git -C "$RF" commit -qm add-f
chmod +x "$RF/f.txt"
assert_ne "fingerprint changes after mode-only change" "$fp1" "$(CA "$RF" fingerprint)"

# complete fingerprint reacts to out-of-scope / protected additions
RS="$(fx_repo_new)"
mkdir -p "$RS/.claude/scripts" "$RS/backend"
printf 'ok\n' > "$RS/.claude/scripts/x.sh"
base_fp="$(CA "$RS" fingerprint)"
printf 'leak\n' > "$RS/backend/leak.txt"
assert_ne "complete fingerprint changes on Protected addition" "$base_fp" "$(CA "$RS" fingerprint)"
rm "$RS/backend/leak.txt"
printf 'oops\n' > "$RS/out-of-scope.txt"
assert_ne "complete fingerprint changes on out-of-scope addition" "$base_fp" "$(CA "$RS" fingerprint)"

# --- symlink fingerprint (byte-preserving, newline in target) --------

RL="$(fx_repo_new)"
tgt="$(printf 'weird\ntarget\npath')"
ln -s "$tgt" "$RL/link"
git -C "$RL" add link >/dev/null; git -C "$RL" commit -qm add-link
stored="$(git -C "$RL" rev-parse :link)"
printf 'other content\n' > "$RL/realfile"
ln -sf realfile "$RL/other" 2>/dev/null || true
LL="$(CA "$RL" list)"
# retarget link and inspect worktree candidate content_id
ln -sfn "$(printf 'weird\ntarget\nDIFFERENT')" "$RL/link"
LL2="$(CA "$RL" list)"
cid2="$(ent "$LL2" link .content_id)"
expect2="$(readlink -n -- "$RL/link" | git hash-object --stdin)"
assert_eq "symlink content_id = git symlink blob of link target" "$expect2" "$cid2"
assert_ne "symlink content_id changes when target string changes" "$stored" "$cid2"
# restore original target, then change only the pointed-to file's content
ln -sfn "$tgt" "$RL/link"
before_link_cid="$(ent "$(CA "$RL" list)" link .content_id 2>/dev/null || true)"
# link now matches HEAD so it may not be a candidate; assert its byte-hash is the stored blob
assert_eq "restored symlink hashes to git's stored blob" "$stored" "$(readlink -n -- "$RL/link" | git hash-object --stdin)"
assert_not_contains "candidate.sh never uses 'git hash-object -- <symlink>' via readlink substitution" \
  "$(grep -n 'hash-object' "$CANDIDATE_SH" | grep -v 'readlink -n' || true)" 'readlink)'

# --- scope classification (incl. rename both-sides) -----------------

RSC="$(fx_repo_new)"
mkdir -p "$RSC/.claude/scripts" "$RSC/.claude/tests" "$RSC/backend"
printf 'a\n' > "$RSC/backend/keep.txt"
printf 'lib\n' > "$RSC/.claude/scripts/lib.sh"
fx_commit "$RSC" seed
printf 'edit\n' >> "$RSC/.claude/scripts/lib.sh"       # allowed
run_capture CA "$RSC" scope --allowed '.claude/scripts/**' --allowed '.claude/tests/**' --protected 'backend/**' --protected 'README.md'
assert_eq "in-scope candidate -> PASS (rc 0)" "0" "$RC"
assert_contains "scope PASS json" "$OUT" '"result":"PASS"'

printf 'tamper\n' >> "$RSC/backend/keep.txt"
run_capture CA "$RSC" scope --allowed '.claude/scripts/**' --protected 'backend/**'
assert_eq "Protected candidate -> FAIL (rc 1)" "1" "$RC"
assert_contains "scope FAIL names CANDIDATE_PROTECTED" "$OUT" 'CANDIDATE_PROTECTED'
git -C "$RSC" checkout -- backend/keep.txt

printf 'stray\n' > "$RSC/rogue.txt"
run_capture CA "$RSC" scope --allowed '.claude/scripts/**' --protected 'backend/**'
assert_contains "out-of-scope candidate -> CANDIDATE_OUT_OF_SCOPE" "$OUT" 'CANDIDATE_OUT_OF_SCOPE'
rm "$RSC/rogue.txt"

# rename: protected source -> allowed destination is rejected
RR="$(fx_repo_new)"
mkdir -p "$RR/protected" "$RR/allowed"
printf 'secret\n' > "$RR/protected/s.txt"
fx_commit "$RR" seed
git -C "$RR" mv protected/s.txt allowed/s.txt
run_capture CA "$RR" scope --allowed 'allowed/**' --protected 'protected/**'
assert_eq "rename with Protected source -> FAIL" "1" "$RC"
assert_contains "rename Protected source names rename_from side" "$OUT" '"side":"rename_from"'
assert_contains "rename Protected source reason" "$OUT" 'CANDIDATE_PROTECTED'

# rename: both sides allowed -> PASS
RR2="$(fx_repo_new)"
mkdir -p "$RR2/allowed"
printf 'ok\n' > "$RR2/allowed/a.txt"
fx_commit "$RR2" seed
git -C "$RR2" mv allowed/a.txt allowed/b.txt
run_capture CA "$RR2" scope --allowed 'allowed/**' --protected 'backend/**'
assert_eq "rename with both sides Allowed -> PASS" "0" "$RC"

# rename: allowed source -> protected destination is rejected
RR3="$(fx_repo_new)"
mkdir -p "$RR3/allowed" "$RR3/protected"
printf 'ok\n' > "$RR3/allowed/a.txt"
fx_commit "$RR3" seed
git -C "$RR3" mv allowed/a.txt protected/a.txt
run_capture CA "$RR3" scope --allowed 'allowed/**' --allowed 'protected/**' --protected 'protected/**'
assert_eq "rename into Protected destination -> FAIL" "1" "$RC"

# --- staged mode ----------------------------------------------------

RST="$(fx_repo_new)"
mkdir -p "$RST/.claude/scripts"
printf 'v1\n' > "$RST/.claude/scripts/keep.sh"
printf 'old\n' > "$RST/gone.txt"
fx_commit "$RST" seed
printf 'v2\n' > "$RST/.claude/scripts/keep.sh"     # modified
git -C "$RST" rm -q gone.txt                        # deletion
printf '#!/bin/sh\n' > "$RST/add.sh"; chmod +x "$RST/add.sh"   # untracked exec add
ln -s keep.sh "$RST/.claude/scripts/link"           # untracked symlink add

reviewed="$TEST_TMP_ROOT/reviewed.$$.json"
CA "$RST" manifest > "$reviewed"
git -C "$RST" add -A
run_capture CA "$RST" staged-compare --reviewed-manifest "$reviewed"
assert_eq "staged == reviewed (all supported kinds) -> ok true, rc 0" "0" "$RC"
assert_contains "staged_matches_reviewed true"  "$OUT" '"staged_matches_reviewed":true'
assert_contains "no_unexpected_staged true"     "$OUT" '"no_unexpected_staged":true'
assert_contains "no_reviewed_left_unstaged true" "$OUT" '"no_reviewed_left_unstaged":true'

# executable + symlink target-mode derivation reproduced field-for-field
sm="$(CA "$RST" staged-manifest)"
assert_eq "untracked exec -> staged mode 100755" "100755" "$(jq -r '.entries[]|select(.path=="add.sh").mode' <<<"$sm")"
assert_eq "untracked symlink -> staged mode 120000" "120000" "$(jq -r '.entries[]|select(.path==".claude/scripts/link").mode' <<<"$sm")"
assert_eq "reviewed exec mode matches staged" "100755" "$(jq -r '.entries[]|select(.path=="add.sh").mode' "$reviewed")"

# unexpected extra staged file
printf 'surprise\n' > "$RST/surprise.txt"; git -C "$RST" add surprise.txt
run_capture CA "$RST" staged-compare --reviewed-manifest "$reviewed"
assert_contains "extra staged file -> no_unexpected_staged false" "$OUT" '"no_unexpected_staged":false'
git -C "$RST" reset -q surprise.txt; rm "$RST/surprise.txt"

# reviewed file left unstaged
RST2="$(fx_repo_new)"
printf 'a\n' > "$RST2/x.txt"; fx_commit "$RST2" seed
printf 'b\n' > "$RST2/x.txt"
rev2="$TEST_TMP_ROOT/reviewed2.$$.json"; CA "$RST2" manifest > "$rev2"
run_capture CA "$RST2" staged-compare --reviewed-manifest "$rev2"
assert_contains "reviewed file left unstaged -> false" "$OUT" '"no_reviewed_left_unstaged":false'

# unexpected untracked non-ignored file after staging
RST3="$(fx_repo_new)"
printf 'a\n' > "$RST3/x.txt"; fx_commit "$RST3" seed
printf 'b\n' > "$RST3/x.txt"
rev3="$TEST_TMP_ROOT/reviewed3.$$.json"; CA "$RST3" manifest > "$rev3"
git -C "$RST3" add x.txt
printf 'later\n' > "$RST3/late.txt"
run_capture CA "$RST3" staged-compare --reviewed-manifest "$rev3"
assert_contains "unexpected untracked after staging -> false" "$OUT" '"no_unexpected_untracked":false'

# rename semantics preserved
RST4="$(fx_repo_new)"
printf 'a\nb\n' > "$RST4/orig.txt"; fx_commit "$RST4" seed
git -C "$RST4" mv orig.txt moved.txt
rev4="$TEST_TMP_ROOT/reviewed4.$$.json"; CA "$RST4" manifest > "$rev4"
git -C "$RST4" add -A
run_capture CA "$RST4" staged-compare --reviewed-manifest "$rev4"
assert_contains "rename semantics preserved when staged as rename" "$OUT" '"rename_semantics_preserved":true'

# ============================================================================
# Review correction round 1 regressions
# ============================================================================

# --- Major 2 / Major 5.1: candidate symlink vs ancestor escape -------------

# A candidate symlink whose FINAL target is outside the repo is still the
# candidate at its OWN repo-relative path; an Allowed symlink stays Allowed.
RSL="$(fx_repo_new)"
mkdir -p "$RSL/.claude/scripts" "$RSL/backend"
printf 'x\n' > "$RSL/backend/keep.txt"
fx_commit "$RSL" seed
ln -s /etc/hosts "$RSL/.claude/scripts/link"      # target outside the repo
run_capture CA "$RSL" scope --allowed '.claude/scripts/**' --allowed '.claude/tests/**' --protected 'backend/**'
assert_eq "candidate symlink to outside target -> scope decided by its own path (PASS)" "0" "$RC"
assert_contains "candidate symlink stays in scope" "$OUT" '"result":"PASS"'
L="$(CA "$RSL" list)"
assert_eq "candidate symlink recorded at its own path" "added" "$(ent "$L" '.claude/scripts/link' .change_type)"
assert_eq "candidate symlink is a symlink entry" "symlink" "$(ent "$L" '.claude/scripts/link' .type)"

# An ANCESTOR directory that resolves outside the repo -> CANDIDATE_OUTSIDE_REPO.
# Construct it: a tracked file's parent directory is replaced by a symlink
# pointing outside the repo, so git reports the file as deleted while its
# ancestor now escapes.
RAE="$(fx_repo_new)"
OUTDIR="$(mktemp -d "$TEST_TMP_ROOT/outside.XXXXXX")"
mkdir -p "$RAE/sub"
printf 'keep\n' > "$RAE/sub/keep.txt"
fx_commit "$RAE" seed
rm -rf "$RAE/sub"
ln -s "$OUTDIR" "$RAE/sub"                        # ancestor now resolves outside
run_capture CA "$RAE" scope --allowed 'sub/**' --allowed '.claude/**' --protected 'backend/**'
assert_eq "ancestor-symlink escape -> scope FAIL (rc 1)" "1" "$RC"
assert_contains "ancestor-symlink escape -> CANDIDATE_OUTSIDE_REPO" "$OUT" 'CANDIDATE_OUTSIDE_REPO'

# --- Major 5.3: filename containing a newline (machine behavior) -----------

RNL="$(fx_repo_new)"
nlname="$(printf 'weird\nname.txt')"
printf 'body\n' > "$RNL/$nlname" 2>/dev/null || printf 'body\n' > "$RNL/weird"$'\n'"name.txt"
if [ -e "$RNL/$nlname" ]; then
  LNL="$(CA "$RNL" list)"
  got_ct="$(jq -r --arg p "$nlname" '.[] | select(.path==$p) | .change_type' <<<"$LNL")"
  assert_eq "newline-in-filename candidate parsed (change_type)" "added" "$got_ct"
  assert_eq "newline-in-filename candidate parsed (count 1)" "1" \
    "$(jq --arg p "$nlname" '[.[] | select(.path==$p)] | length' <<<"$LNL")"
else
  _pass "newline-in-filename skipped (filesystem disallows)"
fi

# --- Major 5.4: rename from out-of-scope source to Allowed destination -----

ROOS="$(fx_repo_new)"
mkdir -p "$ROOS/elsewhere" "$ROOS/allowed"
printf 'x\n' > "$ROOS/elsewhere/a.txt"
fx_commit "$ROOS" seed
git -C "$ROOS" mv elsewhere/a.txt allowed/a.txt
run_capture CA "$ROOS" scope --allowed 'allowed/**' --protected 'backend/**'
assert_eq "rename from out-of-scope source -> FAIL" "1" "$RC"
assert_contains "rename out-of-scope source flagged on rename_from side" "$OUT" '"side":"rename_from"'
assert_contains "rename out-of-scope source -> CANDIDATE_OUT_OF_SCOPE" "$OUT" 'CANDIDATE_OUT_OF_SCOPE'

# --- Major 5.5: fingerprint changes after rename --------------------------

RFR="$(fx_repo_new)"
printf 'a\nb\nc\n' > "$RFR/orig.txt"
fx_commit "$RFR" seed
fp_pre="$(CA "$RFR" fingerprint)"
git -C "$RFR" mv orig.txt renamed.txt
assert_ne "fingerprint changes after a rename" "$fp_pre" "$(CA "$RFR" fingerprint)"

# --- Major 5.2 / Major 3.8: staged whitespace failure -------------------

RSW="$(fx_repo_new)"
printf 'clean\n' > "$RSW/f.txt"
fx_commit "$RSW" seed
printf 'trailing space   \n' > "$RSW/f.txt"
rsw_rev="$(mktemp "$TEST_TMP_ROOT/rsw.XXXXXX.json")"; CA "$RSW" manifest > "$rsw_rev"
git -C "$RSW" add -A
run_capture CA "$RSW" staged-compare --reviewed-manifest "$rsw_rev"
assert_contains "staged whitespace error -> whitespace_clean false" "$OUT" '"whitespace_clean":false'
assert_contains "staged whitespace error -> ok false" "$OUT" '"ok":false'

# ============================================================================
# Major 4: staged-compare semantic rename normalization
# ============================================================================

# Helper: throwaway repo, reviewed manifest captured OUTSIDE the repo.
m4_setup() {
  local r; r="$(fx_repo_new)"
  printf 'line one\nline two\nline three\n' > "$r/a.txt"
  fx_commit "$r" seed
  printf '%s' "$r"
}

# 1. Unstaged filesystem rename -> git detects a rename on `git add` -> PASS.
M4A="$(m4_setup)"
mv "$M4A/a.txt" "$M4A/b.txt"
m4a_rev="$(mktemp "$TEST_TMP_ROOT/m4a.XXXXXX.json")"; CA "$M4A" manifest > "$m4a_rev"
git -C "$M4A" add -A
run_capture CA "$M4A" staged-compare --reviewed-manifest "$m4a_rev"
assert_eq "unstaged fs rename, unchanged content -> ok true (rc 0)" "0" "$RC"
assert_contains "delete+add reviewed equals git-detected rename staged" "$OUT" '"staged_matches_reviewed":true'
assert_contains "rename source not reported as left unstaged" "$OUT" '"no_reviewed_left_unstaged":true'

# 2. Rename plus a content change BEFORE review; exact reviewed content staged -> PASS.
M4B="$(m4_setup)"
mv "$M4B/a.txt" "$M4B/b.txt"
printf 'line one\nline two\nline three\nline four\n' > "$M4B/b.txt"   # changed before review
m4b_rev="$(mktemp "$TEST_TMP_ROOT/m4b.XXXXXX.json")"; CA "$M4B" manifest > "$m4b_rev"
git -C "$M4B" add -A
run_capture CA "$M4B" staged-compare --reviewed-manifest "$m4b_rev"
assert_eq "rename+content-change, exact reviewed content staged -> ok true" "0" "$RC"

# 3. Staged destination differs from reviewed content -> FAIL.
M4C="$(m4_setup)"
mv "$M4C/a.txt" "$M4C/b.txt"
m4c_rev="$(mktemp "$TEST_TMP_ROOT/m4c.XXXXXX.json")"; CA "$M4C" manifest > "$m4c_rev"
printf 'DIFFERENT\n' > "$M4C/b.txt"
git -C "$M4C" add -A
run_capture CA "$M4C" staged-compare --reviewed-manifest "$m4c_rev"
assert_eq "staged destination content != reviewed -> FAIL (rc 1)" "1" "$RC"
assert_contains "staged destination mismatch -> staged_matches_reviewed false" "$OUT" '"staged_matches_reviewed":false'

# 4. Wrong rename source -> FAIL.
M4D="$(m4_setup)"
printf 'unrelated\n' > "$M4D/c.txt"
fx_commit "$M4D" add-c
mv "$M4D/a.txt" "$M4D/b.txt"
m4d_rev="$(mktemp "$TEST_TMP_ROOT/m4d.XXXXXX.json")"; CA "$M4D" manifest > "$m4d_rev"
# stage a DIFFERENT rename (c.txt -> b.txt) instead of the reviewed a.txt -> b.txt
git -C "$M4D" checkout -- a.txt 2>/dev/null || true
rm -f "$M4D/b.txt"
git -C "$M4D" mv c.txt b.txt
git -C "$M4D" add -A
run_capture CA "$M4D" staged-compare --reviewed-manifest "$m4d_rev"
assert_eq "wrong rename source -> FAIL" "1" "$RC"

# 5. Extra delete/add unrelated to the reviewed transition -> FAIL.
M4E="$(m4_setup)"
printf 'x\n' > "$M4E/extra.txt"
fx_commit "$M4E" add-extra
mv "$M4E/a.txt" "$M4E/b.txt"
m4e_rev="$(mktemp "$TEST_TMP_ROOT/m4e.XXXXXX.json")"; CA "$M4E" manifest > "$m4e_rev"
git -C "$M4E" rm -q extra.txt        # an extra transition not in the reviewed manifest
git -C "$M4E" add -A
run_capture CA "$M4E" staged-compare --reviewed-manifest "$m4e_rev"
assert_eq "extra unrelated delete/add -> FAIL" "1" "$RC"
assert_contains "extra staged transition detected" "$OUT" '"no_unexpected_staged":false'

# ============================================================================
# Review correction round 2 regressions
# ============================================================================

# --- Blocking finding 1: literal path_matches positive coverage ----------

# Literal Allowed: a tracked literal file, modified, authorised by an exact
# literal Allowed entry (NOT a /** prefix).
RLA="$(fx_repo_new)"
mkdir -p "$RLA/backend"
printf 'seed\n' > "$RLA/notes.md"
printf 'x\n' > "$RLA/backend/keep.txt"
fx_commit "$RLA" seed
printf 'more notes\n' >> "$RLA/notes.md"
run_capture CA "$RLA" scope --allowed 'notes.md' --protected 'backend/**'
assert_eq       "literal Allowed entry authorises the exact path -> PASS (rc 0)" "0" "$RC"
assert_contains "literal Allowed -> result PASS" "$OUT" '"result":"PASS"'
# a different literal does NOT authorise notes.md
run_capture CA "$RLA" scope --allowed 'other.md' --protected 'backend/**'
assert_eq       "a different literal does not authorise the path -> FAIL (rc 1)" "1" "$RC"
assert_contains "different literal -> CANDIDATE_OUT_OF_SCOPE" "$OUT" 'CANDIDATE_OUT_OF_SCOPE'

# Literal Protected: a tracked literal file, modified; protected wins over an
# Allowed rule that would otherwise permit it. Matching entry is exactly README.md.
RLP="$(fx_repo_new)"
mkdir -p "$RLP/docs"
printf 'root\n' > "$RLP/README.md"
printf 'd\n' > "$RLP/docs/x.md"
fx_commit "$RLP" seed
printf 'edited\n' >> "$RLP/README.md"
run_capture CA "$RLP" scope --allowed 'docs/**' --allowed 'README.md' --protected 'README.md'
assert_eq       "literal Protected wins over Allowed -> FAIL (rc 1)" "1" "$RC"
reason="$(jq -r '.violations[0].reason' <<<"$OUT")"
entry="$(jq -r '.violations[0].entry' <<<"$OUT")"
vpath="$(jq -r '.violations[0].path' <<<"$OUT")"
assert_eq       "literal Protected -> reason CANDIDATE_PROTECTED" "CANDIDATE_PROTECTED" "$reason"
assert_eq       "literal Protected -> matching entry is exactly README.md" "README.md" "$entry"
assert_eq       "literal Protected -> violation path is README.md" "README.md" "$vpath"

# --- Blocking finding 3: tab-containing filename behavioral assertion ----

RTB="$(fx_repo_new)"
tabname="$(printf 'tab\there.txt')"
if printf 'body\n' > "$RTB/$tabname" 2>/dev/null && [ -e "$RTB/$tabname" ]; then
  LTB="$(CA "$RTB" list)"
  assert_eq  "tab-in-filename: exactly one candidate entry for that path" "1" \
    "$(jq --arg p "$tabname" '[.[] | select(.path==$p)] | length' <<<"$LTB")"
  assert_eq  "tab-in-filename: change_type is added"  "added"  "$(jq -r --arg p "$tabname" '.[] | select(.path==$p) | .change_type' <<<"$LTB")"
  assert_eq  "tab-in-filename: tracked is false"      "false"  "$(jq -r --arg p "$tabname" '.[] | select(.path==$p) | .tracked' <<<"$LTB")"
  assert_eq  "tab-in-filename: derived mode 100644"   "100644" "$(jq -r --arg p "$tabname" '.[] | select(.path==$p) | .mode' <<<"$LTB")"
  # the byte-exact tab survives round-trip through candidate parsing
  got="$(jq -r --arg p "$tabname" '.[] | select(.path==$p) | .path' <<<"$LTB")"
  assert_eq  "tab-in-filename: parsed path is byte-identical to the created name" "$tabname" "$got"
  # and it is in scope when Allowed covers its directory prefix
  git -C "$RTB" add -A
  git -C "$RTB" -c user.email=a@b.c -c user.name=x commit -qm add-tab
  printf 'more\n' >> "$RTB/$tabname"
  run_capture CA "$RTB" scope --allowed 'tab	here.txt' --protected 'backend/**'
  # (literal Allowed entry itself contains a tab; matching is a quoted literal)
  assert_eq  "tab-in-filename: literal Allowed entry with a tab matches -> PASS" "0" "$RC"
else
  _pass "tab-in-filename test skipped (filesystem disallows tab in name)"
fi
