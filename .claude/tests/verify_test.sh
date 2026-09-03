#!/usr/bin/env bash
# verify_test.sh — verify.sh

suite "verify"

# repo with backend/ + .claude/ committed; returns repo path
vr_repo() {
  local r; r="$(fx_repo_new)"
  mkdir -p "$r/.claude/scripts" "$r/.claude/tests" "$r/backend" "$r/target"
  printf 'x\n'   > "$r/.claude/scripts/a.sh"
  printf 'p\n'   > "$r/backend/keep.txt"
  printf 'c\n'   > "$r/backend/clean.txt"
  printf 'root\n' > "$r/README.md"
  printf 'services: {}\n' > "$r/docker-compose.yml"
  printf 'target/\n' > "$r/.gitignore"
  fx_commit "$r" seed
  printf '%s' "$r"
}

# run verify.sh with a fake bin dir on PATH and an invocation-log sentinel
VLOG=""
V() {
  local repo="$1" bindir="$2"; shift 2
  VLOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")"
  INVOCATION_LOG="$VLOG" PATH="$bindir:$PATH" \
    bash "$VERIFY_SH" --repo-root "$repo" \
      --allowed '.claude/scripts/**' --allowed '.claude/tests/**' \
      --protected 'backend/**' --protected 'README.md' --protected 'docker-compose.yml' "$@"
}
chk() { jq -r --arg id "$2" '.checks[] | select(.id==$id) | .classification' <<<"$1"; }
fk() { jq -r --arg id "$2" '.checks[] | select(.id==$id) | .failure_kind' <<<"$1"; }

# --- component selection -------------------------------------------

R="$(vr_repo)"; B="$(fx_fakebin_dir)"
fx_fake_cmd "$B" docker 0
printf 'edit\n' >> "$R/.claude/scripts/a.sh"
run_capture V "$R" "$B" --mode worktree
REC="$OUT"
assert_json "verification record is valid JSON" "$REC"
assert_eq "candidate_scope PASS"                "PASS"           "$(chk "$REC" candidate_scope)"
assert_eq "docker_compose_config PASS (fake)"   "PASS"           "$(chk "$REC" docker_compose_config)"
assert_eq "backend_test NOT_APPLICABLE"         "NOT_APPLICABLE" "$(chk "$REC" backend_test)"
assert_eq "backend_package NOT_APPLICABLE"      "NOT_APPLICABLE" "$(chk "$REC" backend_package)"
assert_eq "frontend_build NOT_APPLICABLE"       "NOT_APPLICABLE" "$(chk "$REC" frontend_build)"
assert_contains "NOT_APPLICABLE carries a reason" "$REC" '"no candidate path under backend/"'

# --- scope hard gate stops the suite ------------------------------

RG="$(vr_repo)"; BG="$(fx_fakebin_dir)"
fx_fake_cmd "$BG" docker 0
fx_fake_cmd "$BG" mvn 0
fx_fake_cmd "$BG" npm 0
printf 'tamper\n' >> "$RG/backend/keep.txt"       # Protected candidate
run_capture V "$RG" "$BG" --mode worktree
REC="$OUT"
assert_eq "scope gate -> FAIL_IMPLEMENTATION" "FAIL_IMPLEMENTATION" "$(chk "$REC" candidate_scope)"
assert_eq "scope gate -> CANDIDATE_SCOPE_VIOLATION" "CANDIDATE_SCOPE_VIOLATION" "$(fk "$REC" candidate_scope)"
assert_eq "scope gate -> stopped_early" "true" "$(jq -r '.stopped_early' <<<"$REC")"
assert_eq "scope gate -> stopped_reason" "CANDIDATE_SCOPE_VIOLATION" "$(jq -r '.stopped_reason' <<<"$REC")"
assert_eq "no build/assertion command ran after scope gate" "" "$(cat "$VLOG")"
assert_eq "later checks recorded NOT_RUN" "NOT_RUN" "$(chk "$REC" backend_test)"
assert_contains "scope_violations recorded" "$REC" '"reason":"CANDIDATE_PROTECTED"'

# out-of-scope path also trips the gate
RG2="$(vr_repo)"; BG2="$(fx_fakebin_dir)"; fx_fake_cmd "$BG2" docker 0
printf 'stray\n' > "$RG2/rogue.txt"
run_capture V "$RG2" "$BG2" --mode worktree
assert_eq "out-of-scope path -> scope gate FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" candidate_scope)"

# staged mode: scope gate also applies (staged candidate = index vs HEAD)
RG3="$(vr_repo)"; BG3="$(fx_fakebin_dir)"; fx_fake_cmd "$BG3" docker 0
rm3="$(mktemp "$TEST_TMP_ROOT/rm3.XXXXXX.json")"
printf '{"entries":[]}' > "$rm3"
printf 'tamper\n' >> "$RG3/backend/keep.txt"; git -C "$RG3" add -A
run_capture env PATH="$BG3:$PATH" bash "$VERIFY_SH" --repo-root "$RG3" --mode staged \
  --allowed '.claude/scripts/**' --protected 'backend/**' --protected 'README.md' \
  --reviewed-manifest "$rm3"
assert_eq "scope gate applies in staged mode" "FAIL_IMPLEMENTATION" "$(chk "$OUT" candidate_scope)"
git -C "$RG3" reset -q

# --- command classification (backend touched) --------------------

vr_backend_touched() {  # returns repo with a real in-scope-ish backend change
  local r; r="$(vr_repo)"
  # move backend into allowed scope for these tests
  printf '%s' "$r"
}
# widen scope so a backend candidate is allowed and the backend_* commands run
VB() {
  local repo="$1" bindir="$2"; shift 2
  VLOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")"
  INVOCATION_LOG="$VLOG" PATH="$bindir:$PATH" \
    bash "$VERIFY_SH" --repo-root "$repo" \
      --allowed 'backend/**' --allowed '.claude/scripts/**' \
      --protected 'README.md' --protected 'docker-compose.yml' "$@"
}

RC0="$(vr_repo)"; BC0="$(fx_fakebin_dir)"
fx_fake_cmd "$BC0" docker 0
fx_fake_cmd "$BC0" mvn 0 'printf "Tests run: 7, Failures: 0, Errors: 0, Skipped: 1\n"'
printf 'change\n' >> "$RC0/backend/keep.txt"
run_capture VB "$RC0" "$BC0" --mode worktree
REC="$OUT"
assert_eq "successful backend_test -> PASS" "PASS" "$(chk "$REC" backend_test)"
assert_eq "test counts parsed from surefire line" "7" "$(jq -r '.checks[]|select(.id=="backend_test").test_counts.tests' <<<"$REC")"
assert_eq "package skips tests, still PASS" "PASS" "$(chk "$REC" backend_package)"

RC1="$(vr_repo)"; BC1="$(fx_fakebin_dir)"
fx_fake_cmd "$BC1" docker 0
fx_fake_cmd "$BC1" mvn 1 'printf "BUILD FAILURE: assertion failed\n"'
printf 'change\n' >> "$RC1/backend/keep.txt"
run_capture VB "$RC1" "$BC1" --mode worktree
assert_eq "plain non-zero -> FAIL_IMPLEMENTATION" "FAIL_IMPLEMENTATION" "$(chk "$OUT" backend_test)"

RC2="$(vr_repo)"; BC2="$(fx_fakebin_dir)"
fx_fake_cmd "$BC2" docker 0
fx_fake_cmd "$BC2" mvn 1 'printf "Could not resolve dependencies for project foo\n"'
printf 'change\n' >> "$RC2/backend/keep.txt"
run_capture VB "$RC2" "$BC2" --mode worktree
assert_eq "recognized env failure -> FAIL_ENVIRONMENT" "FAIL_ENVIRONMENT" "$(chk "$OUT" backend_test)"

RC3="$(vr_repo)"; BC3="$(fx_fakebin_dir)"
fx_fake_cmd "$BC3" docker 0
fx_fake_cmd "$BC3" mvn 127 'printf "mvn: command not found\n"'
printf 'change\n' >> "$RC3/backend/keep.txt"
run_capture VB "$RC3" "$BC3" --mode worktree
assert_eq "exit 127 -> TOOL_UNAVAILABLE" "TOOL_UNAVAILABLE" "$(chk "$OUT" backend_test)"

# --- INDETERMINATE + stop (fingerprint capture fails) -----------

RID="$(vr_repo)"; BID="$(fx_fakebin_dir)"
fx_fake_cmd "$BID" docker 0
fx_fake_cmd "$BID" mvn 0
fakecand="$(mktemp "$TEST_TMP_ROOT/fakecand.XXXXXX")"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$3" = manifest ] || [ "$1" = manifest ]; then exit 4; fi\n'
  printf 'exec bash %q "$@"\n' "$CANDIDATE_SH"
} > "$fakecand"; chmod +x "$fakecand"
printf 'change\n' >> "$RID/backend/keep.txt"
VLOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")"
run_capture env INVOCATION_LOG="$VLOG" CANDIDATE_SH="$fakecand" PATH="$BID:$PATH" \
  bash "$VERIFY_SH" --repo-root "$RID" --allowed 'backend/**' --allowed '.claude/scripts/**' \
  --protected 'README.md' --mode worktree
assert_eq "fingerprint capture failure -> INDETERMINATE" "INDETERMINATE" "$(chk "$OUT" docker_compose_config)"
assert_eq "INDETERMINATE stops the suite" "true" "$(jq -r '.stopped_early' <<<"$OUT")"
assert_eq "INDETERMINATE leaves later checks NOT_RUN" "NOT_RUN" "$(chk "$OUT" backend_test)"

# --- verification-created mutation ------------------------------

# exit 0 + mutates a tracked in-scope candidate
RM0="$(vr_repo)"; BM0="$(fx_fakebin_dir)"
fx_fake_cmd "$BM0" docker 0
fx_fake_cmd "$BM0" mvn 0 'printf "MUTATE\n" >> backend/keep.txt'
printf 'change\n' >> "$RM0/backend/keep.txt"
run_capture VB "$RM0" "$BM0" --mode worktree
REC="$OUT"
assert_eq "mutation + exit 0 -> FAIL_WORKTREE_MUTATION" "FAIL_WORKTREE_MUTATION" "$(chk "$REC" backend_test)"
assert_eq "mutation failure kind" "VERIFICATION_MUTATED_CANDIDATE" "$(fk "$REC" backend_test)"
assert_eq "mutation stops the suite" "true" "$(jq -r '.stopped_early' <<<"$REC")"
assert_eq "checks after mutation are NOT_RUN" "NOT_RUN" "$(chk "$REC" backend_package)"
assert_contains "mutation names the changed path" "$REC" 'backend/keep.txt'
assert_contains "mutating file is still changed after verify returns" \
  "$(git -C "$RM0" status --porcelain -- backend/keep.txt)" "backend/keep.txt"
assert_contains "no auto-revert: MUTATE line still present" "$(cat "$RM0/backend/keep.txt")" "MUTATE"

# exit non-zero + mutates -> still FAIL_WORKTREE_MUTATION, exit_code preserved
RM1="$(vr_repo)"; BM1="$(fx_fakebin_dir)"
fx_fake_cmd "$BM1" docker 0
fx_fake_cmd "$BM1" mvn 1 'printf "MUT\n" >> backend/keep.txt'
printf 'change\n' >> "$RM1/backend/keep.txt"
run_capture VB "$RM1" "$BM1" --mode worktree
assert_eq "mutation + non-zero -> FAIL_WORKTREE_MUTATION" "FAIL_WORKTREE_MUTATION" "$(chk "$OUT" backend_test)"
assert_eq "mutation record still preserves exit code" "1" "$(jq -r '.checks[]|select(.id=="backend_test").exit_code' <<<"$OUT")"

# mutation of a previously CLEAN Protected file
RM2="$(vr_repo)"; BM2="$(fx_fakebin_dir)"
fx_fake_cmd "$BM2" docker 0
fx_fake_cmd "$BM2" mvn 0 'printf "TOUCH\n" >> backend/clean.txt'
# widen allowed to backend so the command runs, keep clean.txt out of the initial candidate
printf 'change\n' >> "$RM2/backend/keep.txt"
run_capture VB "$RM2" "$BM2" --mode worktree
assert_eq "verification touching a clean Protected file -> mutation" "FAIL_WORKTREE_MUTATION" "$(chk "$OUT" backend_test)"
assert_contains "clean file named in mutation" "$OUT" 'backend/clean.txt'

# creation of a new out-of-scope / Protected non-ignored file
RM3="$(vr_repo)"; BM3="$(fx_fakebin_dir)"
fx_fake_cmd "$BM3" docker 0
fx_fake_cmd "$BM3" mvn 0 'printf "x\n" > brand-new-out-of-scope.txt'
printf 'change\n' >> "$RM3/backend/keep.txt"
run_capture VB "$RM3" "$BM3" --mode worktree
assert_eq "verification creating a new non-ignored file -> mutation" "FAIL_WORKTREE_MUTATION" "$(chk "$OUT" backend_test)"

# mutation confined to an IGNORED artifact is NOT a mutation
RM4="$(vr_repo)"; BM4="$(fx_fakebin_dir)"
fx_fake_cmd "$BM4" docker 0
fx_fake_cmd "$BM4" mvn 0 'printf "junk\n" > target/generated.txt'
printf 'change\n' >> "$RM4/backend/keep.txt"
run_capture VB "$RM4" "$BM4" --mode worktree
assert_eq "ignored-only write is not a mutation" "PASS" "$(chk "$OUT" backend_test)"

# --- untracked whitespace -------------------------------------

RW="$(vr_repo)"; BW="$(fx_fakebin_dir)"; fx_fake_cmd "$BW" docker 0
printf 'trailing space here   \n' > "$RW/.claude/scripts/new.sh"
run_capture V "$RW" "$BW" --mode worktree
assert_eq "new untracked file with trailing whitespace -> FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" untracked_whitespace)"

# --- assertions ---------------------------------------------

RA="$(vr_repo)"; BA="$(fx_fakebin_dir)"; fx_fake_cmd "$BA" docker 0
printf 'contains-marker-token\n' > "$RA/.claude/scripts/probe.txt"
printf 'edit\n' >> "$RA/.claude/scripts/a.sh"
mk_assert() { printf '%s' "$1" > "$TEST_TMP_ROOT/asrt.$2.json"; printf '%s' "$TEST_TMP_ROOT/asrt.$2.json"; }

af_ok="$(mk_assert '[
  {"id":"has-marker","op":"assert_match","path":".claude/scripts/probe.txt","pattern":"marker-token"},
  {"id":"no-localhost","op":"assert_no_match","path":".claude/scripts/probe.txt","pattern":"localhost"},
  {"id":"file-there","op":"file_exists","path":".claude/scripts/a.sh"},
  {"id":"file-gone","op":"file_not_exists","path":".claude/scripts/does-not-exist"}
]' ok)"
run_capture V "$RA" "$BA" --mode worktree --assertions "$af_ok"
REC="$OUT"
assert_eq "assert_match hit -> PASS"       "PASS" "$(chk "$REC" has-marker)"
assert_eq "assert_no_match miss -> PASS"   "PASS" "$(chk "$REC" no-localhost)"
assert_eq "file_exists -> PASS"            "PASS" "$(chk "$REC" file-there)"
assert_eq "file_not_exists -> PASS"        "PASS" "$(chk "$REC" file-gone)"

af_fail="$(mk_assert '[
  {"id":"want-missing","op":"assert_match","path":".claude/scripts/probe.txt","pattern":"NOPE-not-present"}
]' fail)"
run_capture V "$RA" "$BA" --mode worktree --assertions "$af_fail"
assert_eq "assert_match miss -> FAIL_IMPLEMENTATION" "FAIL_IMPLEMENTATION" "$(chk "$OUT" want-missing)"

# shell metacharacters in a pattern stay data (no execution, deterministic)
sentinel="$TEST_TMP_ROOT/assert-sentinel.$$"
rm -f "$sentinel"
af_meta="$(mk_assert '[
  {"id":"meta","op":"assert_no_match","path":".claude/scripts/probe.txt","pattern":"$(touch '"$sentinel"'); rm -rf / | sh"}
]' meta)"
run_capture V "$RA" "$BA" --mode worktree --assertions "$af_meta"
assert_eq "metacharacter pattern treated as literal data -> PASS" "PASS" "$(chk "$OUT" meta)"
assert_file_absent "assertion pattern did not execute a command" "$sentinel"

af_badop="$(mk_assert '[{"id":"x","op":"run","path":".claude/scripts/a.sh"}]' badop)"
assert_fail_code "unsupported assertion op rejected" ASSERTION_UNSUPPORTED_OP \
  env PATH="$BA:$PATH" bash "$VERIFY_SH" --repo-root "$RA" --allowed '.claude/scripts/**' \
    --protected 'README.md' --mode worktree --assertions "$af_badop"

af_trav="$(mk_assert '[{"id":"x","op":"file_exists","path":"../escape"}]' trav)"
assert_fail_code "assertion path traversal rejected" ASSERTION_PATH_INVALID \
  env PATH="$BA:$PATH" bash "$VERIFY_SH" --repo-root "$RA" --allowed '.claude/scripts/**' \
    --protected 'README.md' --mode worktree --assertions "$af_trav"

printf 'not json {{{' > "$TEST_TMP_ROOT/asrt.malformed.json"
assert_fail_code "malformed assertions JSON rejected" ASSERTION_INPUT_INVALID \
  env PATH="$BA:$PATH" bash "$VERIFY_SH" --repo-root "$RA" --allowed '.claude/scripts/**' \
    --protected 'README.md' --mode worktree --assertions "$TEST_TMP_ROOT/asrt.malformed.json"

# --- Verification Record: metadata only, no raw output --------

RR="$(vr_repo)"; BR="$(fx_fakebin_dir)"
fx_fake_cmd "$BR" docker 0
SENT="UNIQUE-SENTINEL-9f3a-DO-NOT-PERSIST"
fx_fake_cmd "$BR" mvn 0 'printf "%s\n%s\n" "'"$SENT"'" "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0"'
printf 'change\n' >> "$RR/backend/keep.txt"
run_capture VB "$RR" "$BR" --mode worktree --run-id "run-xyz" --issue-number 15
REC="$OUT"
assert_json "record with commands is valid JSON" "$REC"
assert_not_contains "record contains no raw command output" "$REC" "$SENT"
assert_contains "record persists output_sha256" "$REC" '"output_sha256"'
b="$(jq -r '.checks[]|select(.id=="backend_test").output_bytes' <<<"$REC")"
s="$(jq -r '.checks[]|select(.id=="backend_test").output_sha256' <<<"$REC")"
exp_bytes="$(printf '%s\n%s\n' "$SENT" "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0" | wc -c | tr -d ' ')"
exp_sha="$(printf '%s\n%s\n' "$SENT" "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0" | sha256sum | awk '{print $1}')"
assert_eq "output_bytes matches captured output size" "$exp_bytes" "$b"
assert_eq "output_sha256 matches captured output digest" "$exp_sha" "$s"
assert_eq "run_id recorded when supplied"       "run-xyz" "$(jq -r '.run_id' <<<"$REC")"
assert_eq "issue_number recorded when supplied" "15"      "$(jq -r '.issue_number' <<<"$REC")"

R2="$(vr_repo)"; B2="$(fx_fakebin_dir)"; fx_fake_cmd "$B2" docker 0
printf 'edit\n' >> "$R2/.claude/scripts/a.sh"
run_capture V "$R2" "$B2" --mode worktree
assert_eq "run_id null when not supplied"       "null" "$(jq -r '.run_id' <<<"$OUT")"
assert_eq "issue_number null when not supplied" "null" "$(jq -r '.issue_number' <<<"$OUT")"
n_counts="$(jq -r '.checks[] | select(.id=="docker_compose_config") | .test_counts' <<<"$OUT")"
assert_eq "test_counts null when no surefire line" "null" "$n_counts"

# --- --contract-file takes the Markdown issue body (real issue-contract.sh) ----

# Valid contract-file integration: no direct --allowed / --protected.
RCF="$(vr_repo)"; BCF="$(fx_fakebin_dir)"
fx_fake_cmd "$BCF" docker 0; fx_fake_cmd "$BCF" mvn 0; fx_fake_cmd "$BCF" npm 0
cf_valid="$(fx_contract contract-scope)"
printf 'edit\n' >> "$RCF/.claude/scripts/a.sh"
run_capture env PATH="$BCF:$PATH" bash "$VERIFY_SH" --repo-root "$RCF" --mode worktree \
  --contract-file "$cf_valid" --run-id run-cf-1 --issue-number 15
REC="$OUT"
assert_eq          "contract-file: proceeds past argument parsing (exit 0)" "0" "$RC"
assert_not_contains "contract-file: no jq parse error"                      "$ERR" "parse error"
assert_not_contains "contract-file: does not degrade to VERIFY_USAGE"       "$ERR" "VERIFY_USAGE"
assert_json        "contract-file: valid Verification Record produced"      "$REC"
assert_eq          "contract-file: candidate_scope PASS from contract Allowed" "PASS" "$(chk "$REC" candidate_scope)"
assert_eq          "contract-file: verification proceeds (docker check ran)"   "PASS" "$(chk "$REC" docker_compose_config)"
assert_eq          "contract-file: run_id threaded through"                 "run-cf-1" "$(jq -r '.run_id' <<<"$REC")"
assert_eq          "contract-file: issue_number threaded through"           "15" "$(jq -r '.issue_number' <<<"$REC")"

# The loaded scope really comes from the contract: a Protected-path candidate must now fail.
git -C "$RCF" checkout -- .claude/scripts/a.sh
printf 'edit\n' >> "$RCF/backend/keep.txt"
run_capture env PATH="$BCF:$PATH" bash "$VERIFY_SH" --repo-root "$RCF" --mode worktree --contract-file "$cf_valid"
assert_eq "contract-file: backend candidate violates contract-derived Protected" \
  "FAIL_IMPLEMENTATION" "$(chk "$OUT" candidate_scope)"
assert_eq "contract-file: scope failure_kind from contract path" \
  "CANDIDATE_SCOPE_VIOLATION" "$(fk "$OUT" candidate_scope)"
git -C "$RCF" checkout -- backend/keep.txt

# Structurally invalid contract fails closed, not VERIFY_USAGE, and runs nothing.
RIC="$(vr_repo)"; BIC="$(fx_fakebin_dir)"; fx_fake_cmd "$BIC" docker 0
cf_bad="$(fx_contract missing-goal)"
printf 'edit\n' >> "$RIC/.claude/scripts/a.sh"
assert_fail_code "contract-file: invalid contract -> VERIFY_CONTRACT_INVALID" VERIFY_CONTRACT_INVALID \
  env PATH="$BIC:$PATH" bash "$VERIFY_SH" --repo-root "$RIC" --mode worktree --contract-file "$cf_bad"
run_capture env PATH="$BIC:$PATH" bash "$VERIFY_SH" --repo-root "$RIC" --mode worktree --contract-file "$cf_bad"
assert_not_contains "contract-file: invalid contract not degraded to VERIFY_USAGE" "$ERR" "VERIFY_USAGE"
assert_not_contains "contract-file: invalid contract runs no verification checks"  "$OUT" '"checks"'

# Valid contract + out-of-scope candidate -> scope gate stops the suite.
RSV="$(vr_repo)"; BSV="$(fx_fakebin_dir)"; fx_fake_cmd "$BSV" docker 0; fx_fake_cmd "$BSV" mvn 0
cf_sv="$(fx_contract contract-scope)"
SVLOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")"
printf 'stray\n' > "$RSV/rogue.txt"
run_capture env INVOCATION_LOG="$SVLOG" PATH="$BSV:$PATH" \
  bash "$VERIFY_SH" --repo-root "$RSV" --mode worktree --contract-file "$cf_sv"
REC="$OUT"
assert_eq "contract-file + scope violation -> FAIL_IMPLEMENTATION" "FAIL_IMPLEMENTATION" "$(chk "$REC" candidate_scope)"
assert_eq "contract-file + scope violation -> CANDIDATE_SCOPE_VIOLATION" "CANDIDATE_SCOPE_VIOLATION" "$(fk "$REC" candidate_scope)"
assert_eq "contract-file + scope violation -> stopped_early" "true" "$(jq -r '.stopped_early' <<<"$REC")"
assert_eq "contract-file + scope violation -> no later command ran" "" "$(cat "$SVLOG")"
assert_eq "contract-file + scope violation -> later checks NOT_RUN" "NOT_RUN" "$(chk "$REC" backend_test)"

# ============================================================================
# Review correction round 1 regressions
# ============================================================================

# --- Major 1: assertion containment escapes via symlink -----------------

RAC="$(vr_repo)"; BAC="$(fx_fakebin_dir)"; fx_fake_cmd "$BAC" docker 0
ln -s /etc/hostname "$RAC/.claude/scripts/escape"     # lexically inside, resolves outside
printf 'edit\n' >> "$RAC/.claude/scripts/a.sh"
af_esc="$(mk_assert '[
  {"id":"escape-match","op":"assert_match","path":".claude/scripts/escape","pattern":".*"}
]' esc)"
assert_fail_code "assertion path escaping via symlink -> ASSERTION_PATH_INVALID" ASSERTION_PATH_INVALID \
  env PATH="$BAC:$PATH" bash "$VERIFY_SH" --repo-root "$RAC" --mode worktree \
    --allowed '.claude/scripts/**' --protected 'README.md' --assertions "$af_esc"
run_capture env PATH="$BAC:$PATH" bash "$VERIFY_SH" --repo-root "$RAC" --mode worktree \
  --allowed '.claude/scripts/**' --protected 'README.md' --assertions "$af_esc"
assert_ne "escaping assertion cannot be PASS (exit != 0)" "0" "$RC"
assert_not_contains "escaping assertion produced no Verification Record" "$OUT" '"checks"'
assert_not_contains "escaping assertion did not classify anything PASS" "$OUT" '"classification":"PASS"'

# absolute assertion path is rejected (Major 5.6)
af_abs="$(mk_assert '[{"id":"abs","op":"file_exists","path":"/etc/passwd"}]' abs)"
assert_fail_code "absolute assertion path rejected" ASSERTION_PATH_INVALID \
  env PATH="$BAC:$PATH" bash "$VERIFY_SH" --repo-root "$RAC" --mode worktree \
    --allowed '.claude/scripts/**' --protected 'README.md' --assertions "$af_abs"

# --- Major 2.3: scope-helper output unusable -> INDETERMINATE ------------

RSF="$(vr_repo)"; BSF="$(fx_fakebin_dir)"; fx_fake_cmd "$BSF" docker 0; fx_fake_cmd "$BSF" mvn 0
badcand="$(mktemp "$TEST_TMP_ROOT/badcand.XXXXXX")"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [ "$a" = scope ] && { printf "totally not json\\n"; exit 0; }; done\n'
  printf 'exec bash %q "$@"\n' "$CANDIDATE_SH"
} > "$badcand"; chmod +x "$badcand"
printf 'edit\n' >> "$RSF/.claude/scripts/a.sh"
run_capture env INVOCATION_LOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")" CANDIDATE_SH="$badcand" PATH="$BSF:$PATH" \
  bash "$VERIFY_SH" --repo-root "$RSF" --mode worktree \
  --allowed '.claude/scripts/**' --protected 'README.md' --record "$TEST_TMP_ROOT/sf-rec.json"
REC="$OUT"
assert_json  "malformed scope output -> still a valid Verification Record" "$REC"
assert_eq    "malformed scope output -> candidate_scope INDETERMINATE" "INDETERMINATE" "$(chk "$REC" candidate_scope)"
assert_eq    "malformed scope output -> SCOPE_EVALUATION_FAILED" "SCOPE_EVALUATION_FAILED" "$(fk "$REC" candidate_scope)"
assert_eq    "malformed scope output -> stopped_early" "true" "$(jq -r '.stopped_early' <<<"$REC")"
assert_eq    "malformed scope output -> later checks NOT_RUN" "NOT_RUN" "$(chk "$REC" docker_compose_config)"
assert_eq    "malformed scope output -> suite result FAIL" "FAIL" "$(jq -r '.result' <<<"$REC")"

# --- Major 5.7: verification command creates a new Protected file -------

RMP="$(vr_repo)"; BMP="$(fx_fakebin_dir)"
fx_fake_cmd "$BMP" docker 0
fx_fake_cmd "$BMP" mvn 0 'printf "leak\n" > backend/created-by-build.txt'
printf 'change\n' >> "$RMP/backend/keep.txt"
run_capture VB "$RMP" "$BMP" --mode worktree
assert_eq "verification creating a new Protected file -> FAIL_WORKTREE_MUTATION" \
  "FAIL_WORKTREE_MUTATION" "$(chk "$OUT" backend_test)"
assert_eq "new Protected file mutation kind" "VERIFICATION_MUTATED_CANDIDATE" "$(fk "$OUT" backend_test)"
assert_contains "new Protected file named in mutation" "$OUT" 'backend/created-by-build.txt'

# --- Major 5 / Minor: NUL/newline-safe untracked whitespace iteration ---

RNW="$(vr_repo)"; BNW="$(fx_fakebin_dir)"; fx_fake_cmd "$BNW" docker 0
nlfile="$(printf 'weird\nfile with trailing ws   .sh')"
if printf 'bad line   \n' > "$RNW/.claude/scripts/$nlfile" 2>/dev/null && [ -e "$RNW/.claude/scripts/$nlfile" ]; then
  run_capture V "$RNW" "$BNW" --mode worktree
  assert_eq "untracked whitespace check processes a newline-named file (not skipped)" \
    "FAIL_IMPLEMENTATION" "$(chk "$OUT" untracked_whitespace)"
else
  _pass "newline-named untracked whitespace test skipped (filesystem disallows)"
fi

# --- Major 3: staged mode ------------------------------------------------

# staged repo builder: returns "REPO REVIEWED_MANIFEST", capturing the reviewed
# manifest OUTSIDE the repo, then leaving the caller to stage + tweak.
vs_build() {
  local r; r="$(fx_repo_new)"
  mkdir -p "$r/.claude/scripts" "$r/backend"
  printf 'v1\n' > "$r/.claude/scripts/keep.sh"
  printf 'p\n'  > "$r/backend/b.txt"
  printf 'services: {}\n' > "$r/docker-compose.yml"
  printf 'target/\n' > "$r/.gitignore"
  fx_commit "$r" seed
  printf '%s' "$r"
}
VS() {  # VS REPO BINDIR REVIEWED_MANIFEST -- run verify.sh in staged mode
  local repo="$1" bindir="$2" rm="$3"; shift 3
  VLOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")"
  INVOCATION_LOG="$VLOG" PATH="$bindir:$PATH" \
    bash "$VERIFY_SH" --repo-root "$repo" --mode staged --reviewed-manifest "$rm" \
      --allowed '.claude/scripts/**' --allowed '.claude/tests/**' \
      --protected 'backend/**' --protected 'README.md' --protected 'docker-compose.yml' "$@"
}

# 3.1 staged mode without --reviewed-manifest fails closed before verification
RS1="$(vs_build)"; BS1="$(fx_fakebin_dir)"; fx_fake_cmd "$BS1" docker 0
assert_fail_code "staged mode without --reviewed-manifest fails closed" VERIFY_USAGE \
  env PATH="$BS1:$PATH" bash "$VERIFY_SH" --repo-root "$RS1" --mode staged \
    --allowed '.claude/scripts/**' --protected 'backend/**'

# 3.2 exact reviewed candidate staged -> staged gate PASS
RS2="$(vs_build)"; BS2="$(fx_fakebin_dir)"; fx_fake_cmd "$BS2" docker 0
printf 'v2\n' > "$RS2/.claude/scripts/keep.sh"
rm2="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS2" manifest > "$rm2"
git -C "$RS2" add -A
run_capture VS "$RS2" "$BS2" "$rm2"
REC="$OUT"
assert_json "staged: valid Verification Record" "$REC"
assert_eq   "staged exact match -> staged_match PASS" "PASS" "$(chk "$REC" staged_match)"
assert_eq   "staged exact match -> suite continues (docker ran)" "PASS" "$(chk "$REC" docker_compose_config)"
assert_eq   "staged exact match -> result PASS" "PASS" "$(jq -r '.result' <<<"$REC")"

# 3.3 changed staged content -> staged gate FAIL, nothing later runs
RS3="$(vs_build)"; BS3="$(fx_fakebin_dir)"; fx_fake_cmd "$BS3" docker 0; fx_fake_cmd "$BS3" mvn 0
printf 'v2\n' > "$RS3/.claude/scripts/keep.sh"
rm3b="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS3" manifest > "$rm3b"
printf 'v3-DIFFERENT\n' > "$RS3/.claude/scripts/keep.sh"
git -C "$RS3" add -A
run_capture VS "$RS3" "$BS3" "$rm3b"
REC="$OUT"
assert_eq "staged content changed -> staged_match FAIL_IMPLEMENTATION" "FAIL_IMPLEMENTATION" "$(chk "$REC" staged_match)"
assert_eq "staged content changed -> STAGED_CANDIDATE_MISMATCH" "STAGED_CANDIDATE_MISMATCH" "$(fk "$REC" staged_match)"
assert_eq "staged content changed -> stopped_early" "true" "$(jq -r '.stopped_early' <<<"$REC")"
assert_eq "staged mismatch -> no later command ran" "" "$(cat "$VLOG")"
assert_eq "staged mismatch -> docker check NOT_RUN" "NOT_RUN" "$(chk "$REC" docker_compose_config)"
assert_contains "staged mismatch retains staged-compare evidence" "$REC" '"staged_matches_reviewed":false'

# 3.4 extra staged file -> FAIL
RS4="$(vs_build)"; BS4="$(fx_fakebin_dir)"; fx_fake_cmd "$BS4" docker 0
printf 'v2\n' > "$RS4/.claude/scripts/keep.sh"
rm4="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS4" manifest > "$rm4"
printf 'surprise\n' > "$RS4/.claude/scripts/surprise.sh"
git -C "$RS4" add -A
run_capture VS "$RS4" "$BS4" "$rm4"
assert_eq "extra staged file -> staged_match FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" staged_match)"

# 3.5 reviewed candidate omitted from staging -> FAIL
RS5="$(vs_build)"; BS5="$(fx_fakebin_dir)"; fx_fake_cmd "$BS5" docker 0
printf 'v2\n' > "$RS5/.claude/scripts/keep.sh"
printf 'newfile\n' > "$RS5/.claude/scripts/extra.sh"
rm5="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS5" manifest > "$rm5"
git -C "$RS5" add .claude/scripts/keep.sh        # stage only one of the two reviewed files
run_capture VS "$RS5" "$BS5" "$rm5"
assert_eq "reviewed candidate omitted from staging -> staged_match FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" staged_match)"

# 3.6 reviewed file staged then modified again in worktree -> FAIL
RS6="$(vs_build)"; BS6="$(fx_fakebin_dir)"; fx_fake_cmd "$BS6" docker 0
printf 'v2\n' > "$RS6/.claude/scripts/keep.sh"
rm6="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS6" manifest > "$rm6"
git -C "$RS6" add -A
printf 'v2-then-more\n' >> "$RS6/.claude/scripts/keep.sh"      # worktree diverges from index
run_capture VS "$RS6" "$BS6" "$rm6"
assert_eq "reviewed file re-modified in worktree -> staged_match FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" staged_match)"
assert_contains "worktree divergence -> no_reviewed_left_unstaged false" "$OUT" '"no_reviewed_left_unstaged":false'

# 3.7 unexpected untracked non-ignored file -> FAIL
RS7="$(vs_build)"; BS7="$(fx_fakebin_dir)"; fx_fake_cmd "$BS7" docker 0
printf 'v2\n' > "$RS7/.claude/scripts/keep.sh"
rm7="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS7" manifest > "$rm7"
git -C "$RS7" add -A
printf 'stray\n' > "$RS7/.claude/scripts/stray.sh"       # untracked, not in reviewed set
run_capture VS "$RS7" "$BS7" "$rm7"
assert_eq "unexpected untracked file -> staged_match FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" staged_match)"
assert_contains "unexpected untracked -> no_unexpected_untracked false" "$OUT" '"no_unexpected_untracked":false'

# 3.8 staged whitespace error -> FAIL
RS8="$(vs_build)"; BS8="$(fx_fakebin_dir)"; fx_fake_cmd "$BS8" docker 0
printf 'has trailing ws   \n' > "$RS8/.claude/scripts/keep.sh"
rm8="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS8" manifest > "$rm8"
git -C "$RS8" add -A
run_capture VS "$RS8" "$BS8" "$rm8"
assert_eq "staged whitespace error -> staged_match FAIL" "FAIL_IMPLEMENTATION" "$(chk "$OUT" staged_match)"
assert_contains "staged whitespace -> whitespace_clean false" "$OUT" '"whitespace_clean":false'

# 3 (staged mode genuinely operates on the staged candidate; delete+add reviewed
#    vs git-detected staged rename compares equal)
RS9="$(vs_build)"; BS9="$(fx_fakebin_dir)"; fx_fake_cmd "$BS9" docker 0
mv "$RS9/.claude/scripts/keep.sh" "$RS9/.claude/scripts/renamed.sh"
rm9="$(mktemp "$TEST_TMP_ROOT/rm.XXXXXX.json")"; bash "$CANDIDATE_SH" --repo-root "$RS9" manifest > "$rm9"
git -C "$RS9" add -A
run_capture VS "$RS9" "$BS9" "$rm9"
assert_eq "staged git-detected rename equals reviewed delete+add -> staged_match PASS" "PASS" "$(chk "$OUT" staged_match)"

# ============================================================================
# Review correction round 2 regressions
# ============================================================================

# --- Reliability 8: --base-branch / --base-commit threaded into the Record ---

RB8="$(vr_repo)"; BB8="$(fx_fakebin_dir)"; fx_fake_cmd "$BB8" docker 0
printf 'edit\n' >> "$RB8/.claude/scripts/a.sh"
run_capture env PATH="$BB8:$PATH" bash "$VERIFY_SH" --repo-root "$RB8" --mode worktree \
  --allowed '.claude/scripts/**' --protected 'README.md' \
  --base-branch main --base-commit deadbeefcafe
REC="$OUT"
assert_json "record with base args is valid JSON" "$REC"
assert_eq   "base_branch recorded verbatim" "main"          "$(jq -r '.git.base_branch' <<<"$REC")"
assert_eq   "base_commit recorded verbatim" "deadbeefcafe"  "$(jq -r '.git.base_commit' <<<"$REC")"

run_capture V "$RB8" "$BB8" --mode worktree
assert_eq   "base_branch null when omitted" "null" "$(jq -r '.git.base_branch' <<<"$OUT")"
assert_eq   "base_commit null when omitted" "null" "$(jq -r '.git.base_commit' <<<"$OUT")"

# --- Reliability 6 & 7: candidate-list enumeration failure is fail-closed ---

# fake candidate helper: `list` emits partial/broken JSON; everything else real.
mk_badlist() {  # mk_badlist MODE(broken|exit1) -> path to fake candidate.sh
  local mode="$1" p; p="$(mktemp "$TEST_TMP_ROOT/badlist.$mode.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do\n'
    if [ "$mode" = broken ]; then
      printf '  [ "$a" = list ] && { printf "[{\\"path\\":\\"x\\"} []"; exit 0; }\n'
    else
      printf '  [ "$a" = list ] && { printf ""; exit 7; }\n'
    fi
    printf 'done\n'
    printf 'exec bash %q "$@"\n' "$CANDIDATE_SH"
  } > "$p"; chmod +x "$p"
  printf '%s' "$p"
}

for lm in broken exit1; do
  R7="$(vr_repo)"; B7="$(fx_fakebin_dir)"; fx_fake_cmd "$B7" docker 0; fx_fake_cmd "$B7" mvn 0
  bad="$(mk_badlist "$lm")"
  rec7="$TEST_TMP_ROOT/rec7.$lm.json"
  printf 'edit\n' >> "$R7/.claude/scripts/a.sh"
  run_capture env INVOCATION_LOG="$(mktemp "$TEST_TMP_ROOT/vlog.XXXXXX")" CANDIDATE_SH="$bad" PATH="$B7:$PATH" \
    bash "$VERIFY_SH" --repo-root "$R7" --mode worktree \
    --allowed '.claude/scripts/**' --protected 'README.md' --record "$rec7"
  REC="$OUT"
  assert_json  "[$lm] candidate-list failure -> Verification Record is valid JSON" "$REC"
  assert_file_exists "[$lm] record file written" "$rec7"
  assert_json  "[$lm] record file is valid JSON" "$(cat "$rec7")"
  assert_not_contains "[$lm] record does not contain a broken '] []' array" "$REC" '] []'
  # item 7: untracked_whitespace fails closed
  assert_eq    "[$lm] untracked_whitespace -> INDETERMINATE" "INDETERMINATE" "$(chk "$REC" untracked_whitespace)"
  assert_eq    "[$lm] untracked_whitespace -> CANDIDATE_ENUMERATION_FAILED" "CANDIDATE_ENUMERATION_FAILED" "$(fk "$REC" untracked_whitespace)"
  assert_eq    "[$lm] suite stopped early" "true" "$(jq -r '.stopped_early' <<<"$REC")"
  assert_eq    "[$lm] later checks NOT_RUN" "NOT_RUN" "$(chk "$REC" docker_compose_config)"
  # item 6: emit_record represents enumeration as unavailable, stays valid
  assert_eq    "[$lm] candidate.enumeration_ok is false" "false" "$(jq -r '.candidate.enumeration_ok' <<<"$REC")"
  assert_eq    "[$lm] candidate.paths is null (no fallback array concatenated)" "null" "$(jq -r '.candidate.paths' <<<"$REC")"
done

# --- Reliability 9: command-capture cleanup on trap-reachable exits ------

assert_contains "verify.sh installs a capture-cleanup trap for EXIT INT TERM HUP" \
  "$(grep -E "trap +cleanup_capture +EXIT +INT +TERM +HUP" "$VERIFY_SH" || true)" "cleanup_capture"
# after a normal run, no verify-out.* capture file remains under TMPDIR
RC9="$(vr_repo)"; BC9="$(fx_fakebin_dir)"; fx_fake_cmd "$BC9" docker 0
before_n="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'verify-out.*' 2>/dev/null | wc -l)"
printf 'change\n' >> "$RC9/backend/keep.txt"
fx_fake_cmd "$BC9" mvn 0
run_capture VB "$RC9" "$BC9" --mode worktree
after_n="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'verify-out.*' 2>/dev/null | wc -l)"
assert_eq "no verify-out.* capture residue after a normal run" "$before_n" "$after_n"

# --- Minor 11: environment classification regex is conservative ---------

RE1="$(vr_repo)"; BE1="$(fx_fakebin_dir)"; fx_fake_cmd "$BE1" docker 0
fx_fake_cmd "$BE1" mvn 1 'printf "npm ERR! network error while fetching\n"'
printf 'change\n' >> "$RE1/backend/keep.txt"
run_capture VB "$RE1" "$BE1" --mode worktree
assert_eq "recognized 'network error' phrase -> FAIL_ENVIRONMENT" "FAIL_ENVIRONMENT" "$(chk "$OUT" backend_test)"

RE2="$(vr_repo)"; BE2="$(fx_fakebin_dir)"; fx_fake_cmd "$BE2" docker 0
fx_fake_cmd "$BE2" mvn 1 'printf "BUILD FAILURE in module network-utils: NullPointerException\n"'
printf 'change\n' >> "$RE2/backend/keep.txt"
run_capture VB "$RE2" "$BE2" --mode worktree
assert_eq "unrelated string containing 'network' -> FAIL_IMPLEMENTATION" "FAIL_IMPLEMENTATION" "$(chk "$OUT" backend_test)"
