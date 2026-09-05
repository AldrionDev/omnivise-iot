#!/usr/bin/env bash
# lifecycle_test.sh — Issue #19 deterministic Git/GitHub lifecycle helper.
#
# The lifecycle helper is exercised directly here (the orchestration suite covers
# it through the controller). "origin" is a local bare repository under
# $TEST_TMP_ROOT and `gh` is a stub, so no real remote and no real pull request
# is ever touched.

# shellcheck source=lib/orchestrator_fixtures.sh
. "$TESTS_DIR/lib/orchestrator_fixtures.sh"

suite "lifecycle"

LC_REAL_BRANCH_BEFORE="$(git -C "$OMNIVISE_REPO_ROOT" rev-parse --abbrev-ref HEAD)"
LC_REAL_HEAD_BEFORE="$(git -C "$OMNIVISE_REPO_ROOT" rev-parse HEAD)"

lc_boot() {
  local spec; spec="$(fxo_bootstrap "$1" "$2")"
  LC_WT="${spec%%|*}"; spec="${spec#*|}"
  LC_PRIMARY="${spec%%|*}"; spec="${spec#*|}"
  LC_ORIGIN="${spec%%|*}"
}

# lc_reach REPO PHASE — drive a bootstrapped worktree to PHASE with a candidate
# and a captured reviewed manifest.
lc_reach() {
  local r="$1" target="$2"
  fxo_set_verify PASS
  fxo_orch "$r" validate-contract >/dev/null
  fxo_orch "$r" begin-plan >/dev/null
  fxo_orch "$r" begin-implement >/dev/null
  fxo_candidate "$r"
  fxo_orch "$r" verify-worktree >/dev/null
  [ "$target" = VERIFY_WORKTREE ] && return 0
  fxo_orch "$r" begin-review >/dev/null
  [ "$target" = REVIEW ] && return 0
  fxo_orch "$r" review-pass >/dev/null
  [ "$target" = RESOLVE_HUMAN_GATES ] && return 0
  fxo_orch "$r" gates-resolved >/dev/null
  [ "$target" = STAGE ] && return 0
  fxo_orch "$r" stage >/dev/null
  fxo_orch "$r" verify-staged >/dev/null
  [ "$target" = VERIFY_STAGED ] && return 0
  fxo_orch "$r" commit >/dev/null
  [ "$target" = COMMIT ] && return 0
  fxo_orch "$r" push >/dev/null
  [ "$target" = PUSH ] && return 0
  fxo_orch "$r" create-pr >/dev/null
  return 0
}

# ========================================================================
# 1. Invocation authority (defence in depth)
# ========================================================================

lc_boot 60 "Lifecycle authority probe"
A="$LC_WT"
lc_reach "$A" STAGE

assert_fail_code "authority: issue mode cannot call the lifecycle helper" LIFECYCLE_MODE_REQUIRED \
  fxo_lifecycle issue orchestrator "$A" stage
assert_fail_code "authority: framework-maintenance cannot call it" LIFECYCLE_MODE_REQUIRED \
  fxo_lifecycle framework-maintenance orchestrator "$A" stage
assert_fail_code "authority: an unset mode cannot call it" LIFECYCLE_MODE_REQUIRED \
  fxo_lifecycle "-unset-" orchestrator "$A" stage
assert_fail_code "authority: orchestrator mode alone is not enough" LIFECYCLE_DIRECT_INVOCATION_DENIED \
  fxo_lifecycle orchestrator "-unset-" "$A" stage
assert_fail_code "authority: a forged invocation marker value is rejected" LIFECYCLE_DIRECT_INVOCATION_DENIED \
  fxo_lifecycle orchestrator planner "$A" stage
assert_eq "authority: no denied call staged anything" "" "$(git -C "$A" diff --cached --name-only)"

# --- closed operation grammar; no merge operation exists
for op in merge pr-merge rebase reset push-force checkout arbitrary; do
  assert_fail_code "grammar: '$op' is not a lifecycle operation" LIFECYCLE_UNSUPPORTED_OPERATION \
    fxo_lifecycle orchestrator orchestrator "$A" "$op"
done
assert_fail_code "grammar: an empty operation is rejected" LIFECYCLE_USAGE \
  fxo_lifecycle orchestrator orchestrator "$A" ""
assert_not_contains "grammar: the helper defines no merge operation" \
  "$(cat "$LIFECYCLE_SH")" "git_repo merge"
assert_not_contains "grammar: the helper never force-pushes" \
  "$(cat "$LIFECYCLE_SH")" "--force"

# ========================================================================
# 2. Ordering — each operation is bound to exactly one phase
# ========================================================================

lc_boot 61 "Lifecycle ordering probe"
B="$LC_WT"
lc_reach "$B" REVIEW

# stage is refused outside STAGE
assert_fail_code "ordering: stage is refused in REVIEW" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" stage
assert_fail_code "ordering: commit is refused in REVIEW" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" commit
assert_fail_code "ordering: push is refused in REVIEW" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" push
assert_fail_code "ordering: create-pr is refused in REVIEW" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" create-pr
assert_eq "ordering: nothing was staged by the refusals" "" "$(git -C "$B" diff --cached --name-only)"

fxo_orch "$B" review-pass >/dev/null
fxo_orch "$B" gates-resolved >/dev/null
assert_eq "ordering: STAGE reached" "STAGE" "$(fxo_phase "$B")"
assert_fail_code "ordering: commit is refused in STAGE" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" commit

assert_ok "ordering: stage succeeds in STAGE" fxo_lifecycle orchestrator orchestrator "$B" stage
assert_fail_code "ordering: staging twice is refused (index not empty)" LIFECYCLE_INDEX_NOT_EMPTY \
  fxo_lifecycle orchestrator orchestrator "$B" stage

# the commit is bound to COMMIT, which the controller only enters after a
# passing VERIFY_STAGED
B_HEAD="$(git -C "$B" rev-parse HEAD)"
assert_fail_code "ordering: commit is still refused before VERIFY_STAGED" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" commit
assert_eq "ordering: no commit was created" "$B_HEAD" "$(git -C "$B" rev-parse HEAD)"

fxo_orch "$B" verify-staged >/dev/null
assert_fail_code "ordering: push is refused in VERIFY_STAGED" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" push
fxo_orch "$B" commit >/dev/null
assert_ne "ordering: the commit exists after VERIFY_STAGED PASS" "$B_HEAD" "$(git -C "$B" rev-parse HEAD)"

assert_fail_code "ordering: create-pr is refused in COMMIT" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$B" create-pr
fxo_orch "$B" push >/dev/null
: >"$FXO_GH_LOG"
assert_ok "ordering: create-pr succeeds after the push" fxo_orch "$B" create-pr
assert_contains "ordering: gh was asked to create a pull request" "$(cat "$FXO_GH_LOG")" "pr create"

# ========================================================================
# 3. create-pr requires the branch to be on the remote
# ========================================================================

lc_boot 62 "Unpushed PR probe"
U="$LC_WT"
lc_reach "$U" COMMIT
# jump the controller straight to CREATE_PR through the state machine so the
# helper's own "was this pushed?" precondition is what has to catch it
fxo_state "$U" transition PUSH >/dev/null
fxo_state "$U" transition CREATE_PR >/dev/null
assert_fail_code "create-pr: an unpushed branch is refused" LIFECYCLE_NOT_PUSHED \
  fxo_lifecycle orchestrator orchestrator "$U" create-pr

# ========================================================================
# 4. push preconditions
# ========================================================================

lc_boot 63 "Push precondition probe"
W="$LC_WT"
lc_reach "$W" VERIFY_STAGED
fxo_state "$W" transition COMMIT >/dev/null
fxo_state "$W" transition PUSH >/dev/null
assert_fail_code "push: refuses a branch with no commit beyond its base" LIFECYCLE_NOTHING_TO_PUSH \
  fxo_lifecycle orchestrator orchestrator "$W" push

# ========================================================================
# 5. Manifest-derived staging integrity
# ========================================================================

lc_boot 64 "Staging integrity probe"
S="$LC_WT"
lc_reach "$S" STAGE
S_SD="$(fxo_state_dir "$S")"

# an extra, unreviewed file must not be staged by a manifest-derived stage
printf 'unreviewed\n' >"$S/.claude/scripts/unreviewed.sh"
assert_fail_code "staging: a changed candidate is refused" LIFECYCLE_CANDIDATE_CHANGED \
  fxo_lifecycle orchestrator orchestrator "$S" stage
rm -f "$S/.claude/scripts/unreviewed.sh"
assert_ok "staging: the restored candidate stages" fxo_lifecycle orchestrator orchestrator "$S" stage
assert_eq "staging: exactly the reviewed paths are staged" \
  ".claude/scripts/orchestrated.sh" "$(git -C "$S" diff --cached --name-only)"
assert_eq "staging: staged == reviewed by the existing comparison" "true" \
  "$(bash "$CANDIDATE_SH" --repo-root "$S" staged-compare --reviewed-manifest "$S_SD/reviewed-manifest.json" | jq -r '.ok')"

# a post-stage worktree edit is caught by the same existing comparison
printf 'tampered\n' >>"$S/.claude/scripts/orchestrated.sh"
assert_eq "staging: a post-stage edit is detected" "false" \
  "$(bash "$CANDIDATE_SH" --repo-root "$S" staged-compare --reviewed-manifest "$S_SD/reviewed-manifest.json" | jq -r '.ok')"
run_capture fxo_orch "$S" verify-staged
assert_ne "staging: verify-staged rejects a tampered candidate" "0" "$RC"

# --- a missing reviewed manifest is fatal
lc_boot 65 "Missing manifest probe"
N="$LC_WT"
lc_reach "$N" STAGE
rm -f "$(fxo_state_dir "$N")/reviewed-manifest.json"
assert_fail_code "staging: a missing reviewed manifest is fatal" LIFECYCLE_REVIEWED_MANIFEST_MISSING \
  fxo_lifecycle orchestrator orchestrator "$N" stage

# --- deletions and renames travel through the manifest
lc_boot 66 "Rename probe"
D="$LC_WT"
fxo_set_verify PASS
fxo_orch "$D" validate-contract >/dev/null
fxo_orch "$D" begin-plan >/dev/null
fxo_orch "$D" begin-implement >/dev/null
mkdir -p "$D/.claude/tests"
printf 'seed\n' >"$D/.claude/tests/kept.sh"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "seed a tracked file" >/dev/null
git -C "$D" mv .claude/tests/kept.sh .claude/tests/moved.sh
git -C "$D" reset -q
fxo_orch "$D" verify-worktree >/dev/null
fxo_orch "$D" begin-review >/dev/null
fxo_orch "$D" review-pass >/dev/null
fxo_orch "$D" gates-resolved >/dev/null
assert_ok "staging: a rename stages from the manifest" fxo_lifecycle orchestrator orchestrator "$D" stage
D_STAGED="$(git -C "$D" diff --cached --name-only --no-renames)"
assert_contains "staging: the rename destination is staged" "$D_STAGED" ".claude/tests/moved.sh"
assert_contains "staging: the rename source deletion is staged" "$D_STAGED" ".claude/tests/kept.sh"
assert_eq "staging: the renamed candidate still compares equal" "true" \
  "$(bash "$CANDIDATE_SH" --repo-root "$D" staged-compare --reviewed-manifest "$(fxo_state_dir "$D")/reviewed-manifest.json" | jq -r '.ok')"

# ========================================================================
# 6. Deterministic, state-derived messages
# ========================================================================

lc_boot 67 "Message probe"
MSGWT="$LC_WT"
lc_reach "$MSGWT" COMMIT
MSG="$(git -C "$MSGWT" log -1 --pretty=medium)"
assert_contains "messages: the subject carries the branch type" "$MSG" "feat:"
assert_contains "messages: the subject carries the issue title" "$MSG" "Message probe"
assert_contains "messages: the body references the issue number" "$MSG" "Issue: #67"
assert_contains "messages: the body records the run id" "$MSG" "$(fxo_state "$MSGWT" get run_id)"

# ========================================================================
# 7. Deterministic PR evidence (Issue #28)
# ========================================================================
#
# The PR body must be assembled exclusively from workflow-owned persisted
# artefacts, and incomplete or inconsistent evidence must produce NO pull
# request at all. Every probe below therefore also proves that the `gh` stub was
# never asked to create anything.

# lc_reach_pr REPO — drive to CREATE_PR. The controller performs this transition
# itself after a successful push; here the state machine is used directly so the
# lifecycle helper's own evidence gate is what has to react.
lc_reach_pr() {
  local r="$1"
  lc_reach "$r" PUSH
  fxo_state "$r" transition CREATE_PR >/dev/null
}

# lc_no_pr NAME REPO — nothing reached GitHub and no PR body was produced.
lc_no_pr() {
  assert_not_contains "$1: no pull request was created" "$(cat "$FXO_GH_LOG")" "pr create"
  assert_file_absent "$1: no PR body was written" "$(fxo_state_dir "$2")/pr-body.md"
}

# --- complete evidence renders every required field ----------------------

lc_boot 68 "PR evidence probe"
PE="$LC_WT"
lc_reach "$PE" PUSH
assert_fail_code "pr evidence: create-pr is still bound to CREATE_PR" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_lifecycle orchestrator orchestrator "$PE" create-pr
fxo_state "$PE" transition CREATE_PR >/dev/null
PE_SD="$(fxo_state_dir "$PE")"
PE_REC="$PE_SD/records"

: >"$FXO_GH_LOG"
assert_ok "pr evidence: create-pr succeeds with complete evidence" \
  fxo_lifecycle orchestrator orchestrator "$PE" create-pr
PE_BODY="$(cat "$PE_SD/pr-body.md")"

assert_contains "pr evidence: the issue number" "$PE_BODY" "| Issue | #68 |"
assert_contains "pr evidence: the run id comes from workflow state" "$PE_BODY" \
  "| Run id | $(fxo_state "$PE" get run_id) |"
assert_contains "pr evidence: the base branch comes from workflow state" "$PE_BODY" \
  "| Base branch | $(fxo_state "$PE" get base_branch) |"
assert_contains "pr evidence: the base commit comes from workflow state" "$PE_BODY" \
  "| Base commit | $(fxo_state "$PE" get base_commit) |"
assert_contains "pr evidence: the contract hash comes from workflow state" "$PE_BODY" \
  "| Contract hash | $(fxo_state "$PE" get contract_hash) |"
assert_contains "pr evidence: the reviewed fingerprint comes from the reviewed manifest" "$PE_BODY" \
  "| Reviewed candidate fingerprint | $(jq -r '.fingerprint' "$PE_SD/reviewed-manifest.json") |"
assert_contains "pr evidence: the VERIFY_WORKTREE result comes from its record" "$PE_BODY" \
  "| VERIFY_WORKTREE result | $(jq -r '.result' "$PE_REC/verify-worktree.json") |"
assert_contains "pr evidence: the review verdict comes from the review record" "$PE_BODY" \
  "| Independent review verdict | $(jq -r '.verdict' "$PE_REC/review.json") |"
assert_contains "pr evidence: the Critical count comes from the review record" "$PE_BODY" \
  "| Independent review Critical findings | $(jq -r '.critical' "$PE_REC/review.json") |"
assert_contains "pr evidence: the Major count comes from the review record" "$PE_BODY" \
  "| Independent review Major findings | $(jq -r '.major' "$PE_REC/review.json") |"
assert_contains "pr evidence: the Human Gate state comes from its record" "$PE_BODY" \
  "| Human Gate resolution | $(jq -r '.status' "$PE_REC/human-gate.json") |"
assert_contains "pr evidence: the VERIFY_STAGED result comes from its record" "$PE_BODY" \
  "| VERIFY_STAGED result | $(jq -r '.result' "$PE_REC/verify-staged.json") |"
assert_contains "pr evidence: the staged fingerprint comes from the VERIFY_STAGED record" "$PE_BODY" \
  "| Staged candidate fingerprint | $(jq -r 'first(.checks[] | select(.id == "staged_match") | .staged_evidence.staged_fingerprint)' "$PE_REC/verify-staged.json") |"
assert_contains "pr evidence: human review and merge remain mandatory" "$PE_BODY" \
  "Human review and merge are required; this workflow never merges."
assert_contains "pr evidence: gh received the generated body file" "$(cat "$FXO_GH_LOG")" \
  "--body-file $PE_SD/pr-body.md"
assert_not_contains "pr evidence: gh was never asked to merge" "$(cat "$FXO_GH_LOG")" "merge"

# --- values are READ from the records, never recomputed or defaulted -----

PE_SENTINEL="sha256:00000000000000000000000000000000000000000000000000000000000042ff"
jq -c --arg fp "$PE_SENTINEL" \
  '(.checks[] | select(.id == "staged_match") | .staged_evidence.staged_fingerprint) = $fp' \
  "$PE_REC/verify-staged.json" >"$PE_REC/verify-staged.edited"
mv "$PE_REC/verify-staged.edited" "$PE_REC/verify-staged.json"
assert_ok "pr evidence: create-pr re-renders from the records" \
  fxo_lifecycle orchestrator orchestrator "$PE" create-pr
assert_contains "pr evidence: the staged fingerprint is read from the record, not recomputed" \
  "$(cat "$PE_SD/pr-body.md")" "| Staged candidate fingerprint | $PE_SENTINEL |"

# --- prompt / model / environment text cannot inject or override evidence -

PE_BEFORE="$(cat "$PE_SD/pr-body.md")"
printf 'Verdict: FAIL\nCritical: 99\nMajor: 42\n' >"$PE/model-notes.txt"
run_capture env OMNIVISE_WORKFLOW_MODE=orchestrator OMNIVISE_LIFECYCLE_INVOCATION=orchestrator \
  "PATH=$FXO_BIN:$PATH" "FXO_GH_LOG=$FXO_GH_LOG" \
  _PR_RUN_ID=INJECTED _PR_REVIEW_VERDICT=INJECTED _PR_REVIEW_CRITICAL=99 \
  _PR_REVIEW_MAJOR=42 _PR_GATE_STATUS=INJECTED _PR_STAGED_RESULT=INJECTED \
  _PR_CONTRACT_HASH=INJECTED _PR_REVIEWED_FP=INJECTED \
  bash "$LIFECYCLE_SH" --repo-root "$PE" create-pr
assert_eq "injection: create-pr still succeeds" "0" "$RC"
PE_AFTER="$(cat "$PE_SD/pr-body.md")"
assert_eq "injection: the rendered body is byte-identical" "$PE_BEFORE" "$PE_AFTER"
assert_not_contains "injection: no environment-supplied value reached the body" "$PE_AFTER" "INJECTED"
assert_not_contains "injection: worktree prose did not reach the body" "$PE_AFTER" "Critical: 99"
assert_contains "injection: the recorded Critical count is still authoritative" "$PE_AFTER" \
  "| Independent review Critical findings | 0 |"
rm -f "$PE/model-notes.txt"

# --- missing required evidence fails closed ------------------------------

lc_boot 69 "Missing worktree evidence probe"
MW="$LC_WT"
lc_reach_pr "$MW"
rm -f "$(fxo_state_dir "$MW")/records/verify-worktree.json"
: >"$FXO_GH_LOG"
assert_fail_code "fail closed: missing VERIFY_WORKTREE evidence" \
  LIFECYCLE_WORKTREE_VERIFICATION_EVIDENCE_MISSING \
  fxo_lifecycle orchestrator orchestrator "$MW" create-pr
lc_no_pr "fail closed: VERIFY_WORKTREE" "$MW"

lc_boot 70 "Missing review evidence probe"
MR="$LC_WT"
lc_reach_pr "$MR"
rm -f "$(fxo_state_dir "$MR")/records/review.json"
: >"$FXO_GH_LOG"
assert_fail_code "fail closed: missing independent review evidence" \
  LIFECYCLE_REVIEW_EVIDENCE_MISSING \
  fxo_lifecycle orchestrator orchestrator "$MR" create-pr
lc_no_pr "fail closed: review" "$MR"

lc_boot 71 "Missing staged evidence probe"
MS="$LC_WT"
lc_reach_pr "$MS"
rm -f "$(fxo_state_dir "$MS")/records/verify-staged.json"
: >"$FXO_GH_LOG"
assert_fail_code "fail closed: missing VERIFY_STAGED evidence" \
  LIFECYCLE_STAGED_VERIFICATION_EVIDENCE_MISSING \
  fxo_lifecycle orchestrator orchestrator "$MS" create-pr
lc_no_pr "fail closed: VERIFY_STAGED" "$MS"

lc_boot 72 "Missing gate evidence probe"
MG="$LC_WT"
lc_reach_pr "$MG"
rm -f "$(fxo_state_dir "$MG")/records/human-gate.json"
: >"$FXO_GH_LOG"
assert_fail_code "fail closed: missing Human Gate evidence" \
  LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING \
  fxo_lifecycle orchestrator orchestrator "$MG" create-pr
lc_no_pr "fail closed: Human Gate" "$MG"

lc_boot 74 "Missing reviewed manifest evidence probe"
MM="$LC_WT"
lc_reach_pr "$MM"
rm -f "$(fxo_state_dir "$MM")/reviewed-manifest.json"
: >"$FXO_GH_LOG"
assert_fail_code "fail closed: missing reviewed candidate fingerprint" \
  LIFECYCLE_REVIEW_EVIDENCE_MISSING \
  fxo_lifecycle orchestrator orchestrator "$MM" create-pr
lc_no_pr "fail closed: reviewed manifest" "$MM"

# --- stale / mismatched / non-passing evidence fails closed --------------

lc_boot 73 "Stale evidence probe"
ST="$LC_WT"
lc_reach_pr "$ST"
ST_SD="$(fxo_state_dir "$ST")"
ST_REC="$ST_SD/records"
cp "$ST_REC/review.json"          "$ST_REC/review.bak"
cp "$ST_REC/human-gate.json"      "$ST_REC/human-gate.bak"
cp "$ST_REC/verify-worktree.json" "$ST_REC/verify-worktree.bak"
cp "$ST_REC/verify-staged.json"   "$ST_REC/verify-staged.bak"
cp "$ST_SD/reviewed-manifest.json" "$ST_SD/reviewed-manifest.bak"

# st_probe NAME CODE — run create-pr and assert the deterministic refusal.
st_probe() {
  : >"$FXO_GH_LOG"
  assert_fail_code "$1" "$2" fxo_lifecycle orchestrator orchestrator "$ST" create-pr
  lc_no_pr "$1" "$ST"
}

jq -c '.reviewed_fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000bad"' \
  "$ST_REC/review.bak" >"$ST_REC/review.json"
st_probe "stale: review evidence for another candidate" LIFECYCLE_EVIDENCE_STALE
cp "$ST_REC/review.bak" "$ST_REC/review.json"

jq -c '.critical = 3' "$ST_REC/review.bak" >"$ST_REC/review.json"
st_probe "stale: a recorded Critical finding blocks the PR" LIFECYCLE_REVIEW_EVIDENCE_MISSING
jq -c '.major = 2' "$ST_REC/review.bak" >"$ST_REC/review.json"
st_probe "stale: a recorded Major finding blocks the PR" LIFECYCLE_REVIEW_EVIDENCE_MISSING
cp "$ST_REC/review.bak" "$ST_REC/review.json"

jq -c '.contract_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000fee"' \
  "$ST_REC/human-gate.bak" >"$ST_REC/human-gate.json"
st_probe "stale: gate evidence for another contract" LIFECYCLE_EVIDENCE_STALE
jq -c '.status = "unresolved"' "$ST_REC/human-gate.bak" >"$ST_REC/human-gate.json"
st_probe "stale: an unsettled Human Gate blocks the PR" LIFECYCLE_HUMAN_GATE_EVIDENCE_MISSING
cp "$ST_REC/human-gate.bak" "$ST_REC/human-gate.json"

jq -c '.fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000fad"' \
  "$ST_SD/reviewed-manifest.bak" >"$ST_SD/reviewed-manifest.json"
st_probe "stale: the reviewed manifest is not the verified candidate" LIFECYCLE_EVIDENCE_STALE
cp "$ST_SD/reviewed-manifest.bak" "$ST_SD/reviewed-manifest.json"

jq -c '.result = "FAIL"' "$ST_REC/verify-worktree.bak" >"$ST_REC/verify-worktree.json"
st_probe "stale: a non-passing VERIFY_WORKTREE record blocks the PR" \
  LIFECYCLE_WORKTREE_VERIFICATION_EVIDENCE_MISSING
cp "$ST_REC/verify-worktree.bak" "$ST_REC/verify-worktree.json"

jq -c '.result = "FAIL"' "$ST_REC/verify-staged.bak" >"$ST_REC/verify-staged.json"
st_probe "stale: a non-passing VERIFY_STAGED record blocks the PR" \
  LIFECYCLE_STAGED_VERIFICATION_EVIDENCE_MISSING
jq -c '[.checks[] | select(.id != "staged_match")] as $c | .checks = $c' \
  "$ST_REC/verify-staged.bak" >"$ST_REC/verify-staged.json"
st_probe "stale: a VERIFY_STAGED record without a staged fingerprint blocks the PR" \
  LIFECYCLE_STAGED_VERIFICATION_EVIDENCE_MISSING
cp "$ST_REC/verify-staged.bak" "$ST_REC/verify-staged.json"

# the restored evidence set still produces a pull request, so the refusals above
# were caused by the tampering and nothing else
: >"$FXO_GH_LOG"
assert_ok "stale: the restored evidence set creates the pull request" \
  fxo_lifecycle orchestrator orchestrator "$ST" create-pr
assert_contains "stale: the restored run reached gh" "$(cat "$FXO_GH_LOG")" "pr create"

# ========================================================================
# 8. Isolation
# ========================================================================

assert_eq "lifecycle isolation: real repo index unchanged" \
  "" "$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"
assert_eq "lifecycle isolation: real repo branch unchanged" \
  "$LC_REAL_BRANCH_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" rev-parse --abbrev-ref HEAD)"
assert_eq "lifecycle isolation: real repo HEAD unchanged" \
  "$LC_REAL_HEAD_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" rev-parse HEAD)"
