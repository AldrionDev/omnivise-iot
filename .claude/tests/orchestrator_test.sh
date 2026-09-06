#!/usr/bin/env bash
# orchestrator_test.sh — Issue #19 deterministic orchestration controller.
#
# Offline: verify.sh is replaced by a deterministic stub, `gh` is a stub, and
# "origin" is a local bare repository under $TEST_TMP_ROOT.

# shellcheck source=lib/orchestrator_fixtures.sh
. "$TESTS_DIR/lib/orchestrator_fixtures.sh"

suite "orchestrator"

# fxo_bootstrap prints "<worktree>|<primary>|<origin>|<contract>"
boot() {
  local spec; spec="$(fxo_bootstrap "$1" "$2")"
  BOOT_WT="${spec%%|*}"; spec="${spec#*|}"
  BOOT_PRIMARY="${spec%%|*}"; spec="${spec#*|}"
  BOOT_ORIGIN="${spec%%|*}"
  BOOT_CONTRACT="${spec##*|}"
}

# regate REPO VARIANT — replace the stored issue contract with another
# fx_contract variant and realign the recorded contract hash, so the Human Gate
# state (and not a hash drift) is what the orchestrator reacts to. Seen from the
# deterministic layer this is exactly what a maintainer editing the issue's
# Human Gates section does.
regate() {
  local repo="$1" variant="$2" f sd newstate
  f="$(fx_contract "$variant")"
  sd="$(fxo_state_dir "$repo")"
  cp "$f" "$sd/issue-contract.md"
  newstate="$(jq -c --arg h "$(bash "$CONTRACT_SH" hash "$f")" \
    '.contract_hash = $h' "$sd/state.json")"
  printf '%s\n' "$newstate" >"$sd/state.json"
}

# gate_status REPO — the Human Gate status of REPO's stored contract, read
# straight from the deterministic parser.
gate_status() {
  bash "$CONTRACT_SH" human-gates "$(fxo_state_dir "$1")/issue-contract.md" | jq -r '.status'
}

# ========================================================================
# 1. Happy path, phase by phase
# ========================================================================

boot 19 "Add orchestrate issue workflow"
H="$BOOT_WT"
fxo_set_verify PASS

assert_eq "happy: bootstrap phase" "FETCH_ISSUE" "$(fxo_phase "$H")"

run_capture fxo_orch "$H" validate-contract
assert_eq   "happy: validate-contract" "0" "$RC"
assert_eq   "happy: the contract declares no Human Gate" "none" \
  "$(printf '%s' "$OUT" | jq -r '.human_gates')"
assert_eq   "happy: -> VALIDATE_ISSUE" "VALIDATE_ISSUE" "$(fxo_phase "$H")"

run_capture fxo_orch "$H" begin-plan
assert_eq   "happy: begin-plan succeeds" "0" "$RC"
assert_eq   "happy: -> PLAN" "PLAN" "$(fxo_phase "$H")"
assert_eq   "happy: PLAN dispatches the planner" "planner" "$(printf '%s' "$OUT" | jq -r '.dispatch')"

run_capture fxo_orch "$H" begin-implement
assert_eq   "happy: -> IMPLEMENT" "IMPLEMENT" "$(fxo_phase "$H")"
assert_eq   "happy: IMPLEMENT dispatches the implementer" "implementer" "$(printf '%s' "$OUT" | jq -r '.dispatch')"

fxo_candidate "$H"
run_capture fxo_orch "$H" verify-worktree
assert_eq   "happy: verify-worktree PASS" "0" "$RC"
assert_eq   "happy: -> VERIFY_WORKTREE" "VERIFY_WORKTREE" "$(fxo_phase "$H")"
assert_eq   "happy: verification_attempts incremented" "1" "$(fxo_state "$H" get verification_attempts)"

run_capture fxo_orch "$H" begin-review
assert_eq   "happy: -> REVIEW" "REVIEW" "$(fxo_phase "$H")"
assert_eq   "happy: REVIEW dispatches a fresh reviewer" "true" "$(printf '%s' "$OUT" | jq -r '.fresh')"
assert_eq   "happy: review_attempts incremented" "1" "$(fxo_state "$H" get review_attempts)"

H_SD="$(fxo_state_dir "$H")"
H_REC="$H_SD/records"
assert_file_absent "happy: no reviewed manifest exists before review PASS" "$H_SD/reviewed-manifest.json"
assert_file_absent "happy: no review evidence exists before review PASS" "$H_REC/review.json"

run_capture fxo_orch "$H" review-pass
assert_eq   "happy: -> RESOLVE_HUMAN_GATES" "RESOLVE_HUMAN_GATES" "$(fxo_phase "$H")"
assert_file_exists "happy: reviewed manifest captured before staging" "$H_SD/reviewed-manifest.json"
assert_eq   "happy: reviewed manifest matches the candidate fingerprint" \
  "$(bash "$CANDIDATE_SH" --repo-root "$H" fingerprint)" \
  "$(jq -r '.fingerprint' "$H_SD/reviewed-manifest.json")"
assert_eq   "happy: workflow evidence is not a candidate file" \
  "1" "$(bash "$CANDIDATE_SH" --repo-root "$H" list | jq 'length')"

# --- Issue #28: deterministic independent-review evidence
assert_file_exists "evidence: review-pass persists independent review evidence" "$H_REC/review.json"
assert_eq "evidence: the recorded review verdict" "PASS" "$(jq -r '.verdict' "$H_REC/review.json")"
assert_eq "evidence: the recorded Critical count" "0" "$(jq -r '.critical' "$H_REC/review.json")"
assert_eq "evidence: the recorded Major count" "0" "$(jq -r '.major' "$H_REC/review.json")"
assert_eq "evidence: the review record is tied to the reviewed candidate" \
  "$(jq -r '.fingerprint' "$H_SD/reviewed-manifest.json")" \
  "$(jq -r '.reviewed_fingerprint' "$H_REC/review.json")"
assert_eq "evidence: the review record's authority is the orchestration event" \
  "orchestration-event" "$(jq -r '.source' "$H_REC/review.json")"
assert_eq "evidence: the review record persists only deterministic fields" \
  "critical,event,issue_number,major,recorded_at,review_attempts,review_correction_rounds,reviewed_fingerprint,run_id,schema_version,source,verdict" \
  "$(jq -r '[keys[]] | join(",")' "$H_REC/review.json")"
# Issue #24 correction round 1: the review record carries its own provenance, in
# the same JSON types the state document uses.
assert_eq "evidence: the review record names the run that produced it" \
  "$(fxo_state "$H" get run_id)" "$(jq -r '.run_id' "$H_REC/review.json")"
assert_eq "evidence: the review record names the issue it reviewed" \
  "$(fxo_state "$H" get issue_number)" "$(jq -r '.issue_number' "$H_REC/review.json")"
assert_eq "evidence: the review record's issue number is a JSON number" \
  "number" "$(jq -r '.issue_number | type' "$H_REC/review.json")"

assert_file_absent "evidence: no gate evidence exists before gates-resolved" "$H_REC/human-gate.json"
run_capture fxo_orch "$H" gates-resolved
assert_eq "happy: gates-resolved (contract declares None)" "0" "$RC"
assert_eq "happy: -> STAGE" "STAGE" "$(fxo_phase "$H")"

# --- Issue #28: explicit Human Gate settlement evidence
assert_file_exists "evidence: gates-resolved persists the gate settlement" "$H_REC/human-gate.json"
assert_eq "evidence: the recorded Human Gate state" "none" "$(jq -r '.status' "$H_REC/human-gate.json")"
assert_eq "evidence: the gate settlement is reported by the event" "none" \
  "$(printf '%s' "$OUT" | jq -r '.human_gates')"
assert_eq "evidence: the gate record is tied to the recorded contract" \
  "$(fxo_state "$H" get contract_hash)" "$(jq -r '.contract_hash' "$H_REC/human-gate.json")"
assert_eq "evidence: the gate record's authority is the contract parser" \
  "issue-contract-parser" "$(jq -r '.source' "$H_REC/human-gate.json")"
assert_eq "happy: the index is still empty entering STAGE" "" "$(git -C "$H" diff --cached --name-only)"

assert_ok "happy: stage" fxo_orch "$H" stage
assert_eq "happy: staging is manifest-derived" \
  ".claude/scripts/orchestrated.sh" "$(git -C "$H" diff --cached --name-only)"
assert_eq "happy: stage does not change the phase" "STAGE" "$(fxo_phase "$H")"

assert_ok "happy: verify-staged" fxo_orch "$H" verify-staged
assert_eq "happy: -> VERIFY_STAGED" "VERIFY_STAGED" "$(fxo_phase "$H")"
assert_eq "happy: the staged candidate equals the reviewed candidate" "true" \
  "$(bash "$CANDIDATE_SH" --repo-root "$H" staged-compare --reviewed-manifest "$H_SD/reviewed-manifest.json" | jq -r '.ok')"

H_BEFORE_COMMIT="$(git -C "$H" rev-parse HEAD)"
assert_ok "happy: commit" fxo_orch "$H" commit
assert_eq "happy: -> COMMIT" "COMMIT" "$(fxo_phase "$H")"
assert_ne "happy: a commit was created" "$H_BEFORE_COMMIT" "$(git -C "$H" rev-parse HEAD)"
assert_contains "happy: the commit message is generated from state" \
  "$(git -C "$H" log -1 --pretty=full)" "Issue: #19"

assert_ok "happy: push" fxo_orch "$H" push
assert_eq "happy: -> PUSH" "PUSH" "$(fxo_phase "$H")"
assert_eq "happy: the branch reached the disposable origin" \
  "$(git -C "$H" rev-parse HEAD)" \
  "$(git -C "$BOOT_ORIGIN" rev-parse "refs/heads/$(fxo_state "$H" get feature_branch)")"

: >"$FXO_GH_LOG"
run_capture fxo_orch "$H" create-pr
assert_eq "happy: create-pr succeeds" "0" "$RC"
assert_eq "happy: -> PR_READY_FOR_HUMAN_REVIEW" "PR_READY_FOR_HUMAN_REVIEW" "$(fxo_phase "$H")"
assert_eq "happy: the PR number is recorded" "4242" "$(fxo_state "$H" get pr_number)"
assert_contains "happy: the PR URL is recorded" "$(fxo_state "$H" get pr_url)" "/pull/4242"
assert_contains "happy: gh created a pull request" "$(cat "$FXO_GH_LOG")" "pr create"
assert_not_contains "happy: gh was never asked to merge" "$(cat "$FXO_GH_LOG")" "merge"

# --- Issue #28: the controller's PR carries the recorded workflow evidence
H_BODY="$(cat "$H_SD/pr-body.md")"
assert_contains "evidence: the PR body carries the run id" "$H_BODY" \
  "| Run id | $(fxo_state "$H" get run_id) |"
assert_contains "evidence: the PR body carries the base commit" "$H_BODY" \
  "| Base commit | $(fxo_state "$H" get base_commit) |"
assert_contains "evidence: the PR body carries the VERIFY_WORKTREE result" "$H_BODY" \
  "| VERIFY_WORKTREE result | PASS |"
assert_contains "evidence: the PR body carries the review verdict" "$H_BODY" \
  "| Independent review verdict | PASS |"
assert_contains "evidence: the PR body carries the VERIFY_STAGED result" "$H_BODY" \
  "| VERIFY_STAGED result | PASS |"
assert_contains "evidence: the PR body carries the staged candidate fingerprint" "$H_BODY" \
  "| Staged candidate fingerprint | $(jq -r 'first(.checks[] | select(.id == "staged_match") | .staged_evidence.staged_fingerprint)' "$H_REC/verify-staged.json") |"
assert_contains "evidence: human review and merge remain mandatory" "$H_BODY" \
  "Human review and merge are required; this workflow never merges."

assert_eq "happy: no model reasoning is persisted in workflow state" \
  "$(fxo_state "$H" status | jq -r '[keys[]] | join(",")')" \
  "allowed_paths,base_branch,base_commit,blocker_code,blocker_message,contract_hash,created_at,feature_branch,impl_repair_attempts,issue_number,issue_title,issue_url,phase,pr_number,pr_url,protected_paths,repo_root,resume_phase,review_attempts,review_correction_rounds,run_id,schema_version,updated_at,verification_attempts"

# terminal: no further orchestration event is legal
assert_fail "happy: PR_READY is terminal for orchestration events" fxo_orch "$H" begin-plan

# ========================================================================
# 2. Implementation repair loop
# ========================================================================

boot 23 "Repair loop probe"
R="$BOOT_WT"
fxo_orch "$R" validate-contract >/dev/null
fxo_orch "$R" begin-plan >/dev/null
fxo_orch "$R" begin-implement >/dev/null
fxo_candidate "$R"
fxo_set_verify FAIL_IMPLEMENTATION

run_capture fxo_orch "$R" verify-worktree
assert_ne "repair: FAIL_IMPLEMENTATION exits non-zero" "0" "$RC"
assert_eq "repair: -> REPAIR_IMPLEMENTATION" "REPAIR_IMPLEMENTATION" "$(fxo_phase "$R")"
assert_eq "repair: impl_repair_attempts = 1" "1" "$(fxo_state "$R" get impl_repair_attempts)"
assert_eq "repair: the implementer is re-dispatched" "implementer" "$(printf '%s' "$OUT" | jq -r '.dispatch')"

fxo_orch "$R" verify-worktree >/dev/null 2>&1 || true
assert_eq "repair: second repair allowed" "2" "$(fxo_state "$R" get impl_repair_attempts)"
assert_eq "repair: still in REPAIR_IMPLEMENTATION" "REPAIR_IMPLEMENTATION" "$(fxo_phase "$R")"

run_capture fxo_orch "$R" verify-worktree
assert_ne "repair: exhaustion stops the loop" "0" "$RC"
assert_eq "repair: exhaustion -> MANUAL_REVIEW_REQUIRED" "MANUAL_REVIEW_REQUIRED" "$(fxo_phase "$R")"
assert_eq "repair: the repair budget is not exceeded" "2" "$(fxo_state "$R" get impl_repair_attempts)"
assert_eq "repair: the blocker is recorded" "IMPL_REPAIR_BUDGET_EXHAUSTED" "$(fxo_state "$R" get blocker_code)"
assert_eq "repair: review correction rounds untouched" "0" "$(fxo_state "$R" get review_correction_rounds)"
assert_eq "repair: verification attempts are monotonic" "3" "$(fxo_state "$R" get verification_attempts)"

# recovery: a maintainer resumes to the recorded phase
run_capture fxo_orch "$R" resume
assert_eq "repair: resume returns to the recorded phase" "VERIFY_WORKTREE" "$(fxo_phase "$R")"
assert_eq "repair: resume clears the blocker" "" "$(fxo_state "$R" get blocker_code)"

# ========================================================================
# 3. Review correction rounds
# ========================================================================

boot 24 "Review correction probe"
C="$BOOT_WT"
fxo_set_verify PASS
fxo_drive_to_review "$C"
assert_eq "correction: review_attempts = 1" "1" "$(fxo_state "$C" get review_attempts)"
assert_eq "correction: correction rounds = 0" "0" "$(fxo_state "$C" get review_correction_rounds)"

# --- evidence-only reassessment consumes no correction round
run_capture fxo_orch "$C" review-reassess
assert_eq "correction: -> REASSESS_REVIEW" "REASSESS_REVIEW" "$(fxo_phase "$C")"
assert_eq "correction: reassessment consumes no correction round" "false" \
  "$(printf '%s' "$OUT" | jq -r '.consumes_correction_round')"
assert_eq "correction: correction rounds still 0 after reassessment" \
  "0" "$(fxo_state "$C" get review_correction_rounds)"
run_capture fxo_orch "$C" reassess-complete
assert_eq "correction: reassessment returns to REVIEW" "REVIEW" "$(fxo_phase "$C")"
assert_eq "correction: reassessment uses a fresh reviewer" "true" "$(printf '%s' "$OUT" | jq -r '.fresh')"
assert_eq "correction: review_attempts = 2 after reassessment" "2" "$(fxo_state "$C" get review_attempts)"
assert_eq "correction: correction rounds unchanged by reassessment" \
  "0" "$(fxo_state "$C" get review_correction_rounds)"

# --- round 1: blocking finding
run_capture fxo_orch "$C" review-changes-required
assert_eq "correction: blocking finding enters FIX" "FIX" "$(fxo_phase "$C")"
assert_eq "correction: correction round 1 recorded" "1" "$(fxo_state "$C" get review_correction_rounds)"
assert_eq "correction: FIX dispatches the implementer" "implementer" "$(printf '%s' "$OUT" | jq -r '.dispatch')"

# a corrected candidate must be re-verified before a fresh review
fxo_candidate "$C" corrected-1.sh
assert_fail_code "correction: review is refused while the candidate is unverified" \
  ORCHESTRATOR_PHASE_MISMATCH fxo_orch "$C" begin-review
assert_ok "correction: the corrected candidate is re-verified" fxo_orch "$C" verify-worktree
run_capture fxo_orch "$C" begin-review
assert_eq "correction: fresh review after correction" "REVIEW" "$(fxo_phase "$C")"
assert_eq "correction: review_attempts = 3" "3" "$(fxo_state "$C" get review_attempts)"
assert_eq "correction: correction rounds independent of review attempts" \
  "1" "$(fxo_state "$C" get review_correction_rounds)"

# --- round 2
fxo_orch "$C" review-changes-required >/dev/null
assert_eq "correction: correction round 2 recorded" "2" "$(fxo_state "$C" get review_correction_rounds)"
fxo_candidate "$C" corrected-2.sh
fxo_orch "$C" verify-worktree >/dev/null
fxo_orch "$C" begin-review >/dev/null

# --- round 3 is refused
run_capture fxo_orch "$C" review-changes-required
assert_ne "correction: a third correction round is refused" "0" "$RC"
assert_eq "correction: exhaustion -> MANUAL_REVIEW_REQUIRED" "MANUAL_REVIEW_REQUIRED" "$(fxo_phase "$C")"
assert_eq "correction: the correction budget is not exceeded" "2" "$(fxo_state "$C" get review_correction_rounds)"
assert_eq "correction: the blocker is recorded" \
  "REVIEW_CORRECTION_BUDGET_EXHAUSTED" "$(fxo_state "$C" get blocker_code)"
assert_eq "correction: implementation repair budget untouched" "0" "$(fxo_state "$C" get impl_repair_attempts)"

# ========================================================================
# 4. Candidate freshness and staging integrity
# ========================================================================

boot 25 "Freshness probe"
F="$BOOT_WT"
fxo_set_verify PASS
fxo_orch "$F" validate-contract >/dev/null
fxo_orch "$F" begin-plan >/dev/null
fxo_orch "$F" begin-implement >/dev/null
fxo_candidate "$F"
fxo_orch "$F" verify-worktree >/dev/null
# the candidate changes after the passing verification
fxo_candidate "$F" sneaked-in.sh
assert_fail_code "freshness: review is refused when the candidate changed" \
  ORCHESTRATOR_CANDIDATE_CHANGED fxo_orch "$F" begin-review
# There is no free re-verification: a post-verification implementation change
# must travel the repair route, which the state machine also refuses to skip.
assert_fail_code "freshness: re-verification cannot be taken from VERIFY_WORKTREE" \
  ORCHESTRATOR_PHASE_MISMATCH fxo_orch "$F" verify-worktree
assert_eq "freshness: the refusals changed nothing" "VERIFY_WORKTREE" "$(fxo_phase "$F")"

# a dirty index before review is refused
boot 26 "Index probe"
I="$BOOT_WT"
fxo_set_verify PASS
fxo_orch "$I" validate-contract >/dev/null
fxo_orch "$I" begin-plan >/dev/null
fxo_orch "$I" begin-implement >/dev/null
fxo_candidate "$I"
fxo_orch "$I" verify-worktree >/dev/null
git -C "$I" add .claude/scripts/orchestrated.sh >/dev/null
assert_fail_code "staging: review is refused while the index is not empty" \
  ORCHESTRATOR_INDEX_NOT_EMPTY fxo_orch "$I" begin-review

# ========================================================================
# 5. Off-ramps
# ========================================================================

# --- contract clarification
boot 27 "Contract probe"
O="$BOOT_WT"
run_capture fxo_orch "$O" block --code CONTRACT_AMBIGUOUS
assert_ne "offramp: block exits non-zero" "0" "$RC"
assert_eq "offramp: contract ambiguity -> CONTRACT_CLARIFICATION_REQUIRED" \
  "CONTRACT_CLARIFICATION_REQUIRED" "$(fxo_phase "$O")"
assert_eq "offramp: resume phase recorded" "FETCH_ISSUE" "$(fxo_state "$O" get resume_phase)"
assert_ok "offramp: resume returns to the recorded phase" fxo_orch "$O" resume
assert_eq "offramp: resumed to FETCH_ISSUE" "FETCH_ISSUE" "$(fxo_phase "$O")"

# --- a corrupted stored contract fails closed
boot 28 "Corrupt contract probe"
X="$BOOT_WT"
printf 'not a contract at all\n' >"$(fxo_state_dir "$X")/issue-contract.md"
run_capture fxo_orch "$X" validate-contract
assert_ne "offramp: an invalid stored contract fails" "0" "$RC"
assert_eq "offramp: invalid contract -> CONTRACT_CLARIFICATION_REQUIRED" \
  "CONTRACT_CLARIFICATION_REQUIRED" "$(fxo_phase "$X")"
assert_eq "offramp: the blocker is CONTRACT_INVALID" "CONTRACT_INVALID" "$(fxo_state "$X" get blocker_code)"

# --- a contract that no longer matches the recorded hash fails closed
boot 29 "Hash probe"
Y="$BOOT_WT"
Y_ALT="$(fx_contract disjoint)"
cp "$Y_ALT" "$(fxo_state_dir "$Y")/issue-contract.md"
run_capture fxo_orch "$Y" validate-contract
assert_eq "offramp: contract hash drift -> CONTRACT_CLARIFICATION_REQUIRED" \
  "CONTRACT_CLARIFICATION_REQUIRED" "$(fxo_phase "$Y")"
assert_eq "offramp: the blocker is CONTRACT_HASH_MISMATCH" \
  "CONTRACT_HASH_MISMATCH" "$(fxo_state "$Y" get blocker_code)"

# (the unresolved-Human-Gate off-ramp is a pre-staging concern; it is covered in
# section 6, together with the rest of the Human Gate sequencing)

# --- environment failure
boot 31 "Environment probe"
E="$BOOT_WT"
fxo_set_verify PASS
fxo_orch "$E" validate-contract >/dev/null
fxo_orch "$E" begin-plan >/dev/null
fxo_orch "$E" begin-implement >/dev/null
fxo_candidate "$E"
fxo_set_verify FAIL_ENVIRONMENT
run_capture fxo_orch "$E" verify-worktree
assert_ne "offramp: an environment failure exits non-zero" "0" "$RC"
assert_eq "offramp: environment failure -> WAITING_ENVIRONMENT" "WAITING_ENVIRONMENT" "$(fxo_phase "$E")"
assert_eq "offramp: the blocker is ENVIRONMENT_FAILURE" "ENVIRONMENT_FAILURE" "$(fxo_state "$E" get blocker_code)"
assert_eq "offramp: the environment failure consumed no repair attempt" \
  "0" "$(fxo_state "$E" get impl_repair_attempts)"
assert_ok "offramp: WAITING_ENVIRONMENT resumes" fxo_orch "$E" resume
assert_eq "offramp: resumed to VERIFY_WORKTREE" "VERIFY_WORKTREE" "$(fxo_phase "$E")"

# --- candidate mutation is terminal
boot 32 "Mutation probe"
M="$BOOT_WT"
fxo_orch "$M" validate-contract >/dev/null
fxo_orch "$M" begin-plan >/dev/null
fxo_orch "$M" begin-implement >/dev/null
fxo_candidate "$M"
fxo_set_verify FAIL_WORKTREE_MUTATION
run_capture fxo_orch "$M" verify-worktree
assert_eq "offramp: a mutated candidate -> FAILED" "FAILED" "$(fxo_phase "$M")"
assert_fail "offramp: FAILED is terminal" fxo_orch "$M" resume

# --- unknown blocker codes fail closed
boot 33 "Blocker grammar probe"
B="$BOOT_WT"
assert_fail_code "offramp: an unknown blocker code is rejected" ORCHESTRATOR_BLOCKER_UNKNOWN \
  fxo_orch "$B" block --code TOTALLY_MADE_UP
assert_fail_code "offramp: a lower-case blocker code is rejected" ORCHESTRATOR_USAGE \
  fxo_orch "$B" block --code contract_invalid
assert_fail_code "offramp: block without a code is rejected" ORCHESTRATOR_USAGE \
  fxo_orch "$B" block
assert_eq "offramp: a rejected block left the phase alone" "FETCH_ISSUE" "$(fxo_phase "$B")"

# ========================================================================
# 6. Human Gate sequencing (Issue #24 — regression for the #20 smoke test)
# ========================================================================
#
# A Human Gate is settled by the maintainer immediately before staging, so
# initial contract validation may only check that the Human Gates section is
# STRUCTURALLY valid. The #20 smoke run failed because `validate-contract`
# demanded settlement and sent a legitimate, deliberately-open pre-staging gate
# to HUMAN_DECISION_REQUIRED straight out of FETCH_ISSUE.

# --- the exact #20 scenario: one valid unresolved checkbox gate
boot 30 "Human gate sequencing probe"
G="$BOOT_WT"
fxo_set_verify PASS
regate "$G" gates-unresolved

run_capture fxo_orch "$G" validate-contract
assert_eq "gate seq: an unresolved gate does not block contract validation" "0" "$RC"
assert_eq "gate seq: the accepted gate state is reported" "unresolved" \
  "$(printf '%s' "$OUT" | jq -r '.human_gates')"
assert_eq "gate seq: validation still advances to VALIDATE_ISSUE" \
  "VALIDATE_ISSUE" "$(fxo_phase "$G")"
assert_eq "gate seq: no blocker is recorded at contract validation" \
  "" "$(fxo_state "$G" get blocker_code)"

# the four working phases run with the gate still open
assert_ok "gate seq: PLAN runs with an unresolved gate"       fxo_orch "$G" begin-plan
assert_ok "gate seq: IMPLEMENT runs with an unresolved gate"  fxo_orch "$G" begin-implement
fxo_candidate "$G"
assert_ok "gate seq: VERIFY_WORKTREE runs with an unresolved gate" fxo_orch "$G" verify-worktree
assert_ok "gate seq: REVIEW runs with an unresolved gate"     fxo_orch "$G" begin-review
assert_eq "gate seq: the gate stayed unresolved throughout" "unresolved" "$(gate_status "$G")"

# STAGE is unreachable at every point while the gate is open
assert_fail_code "gate seq: STAGE is unreachable from REVIEW" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_orch "$G" stage
assert_ok "gate seq: review-pass" fxo_orch "$G" review-pass
assert_eq "gate seq: -> RESOLVE_HUMAN_GATES" "RESOLVE_HUMAN_GATES" "$(fxo_phase "$G")"
assert_fail_code "gate seq: STAGE is unreachable from RESOLVE_HUMAN_GATES" \
  ORCHESTRATOR_PHASE_MISMATCH fxo_orch "$G" stage

# the gate is enforced here, and only here
run_capture fxo_orch "$G" gates-resolved
assert_ne "gate seq: an unresolved gate refuses gates-resolved" "0" "$RC"
assert_eq "gate seq: unresolved gate -> HUMAN_DECISION_REQUIRED" \
  "HUMAN_DECISION_REQUIRED" "$(fxo_phase "$G")"
assert_eq "gate seq: the blocker is HUMAN_GATE_UNRESOLVED" \
  "HUMAN_GATE_UNRESOLVED" "$(fxo_state "$G" get blocker_code)"
assert_eq "gate seq: the blocker message is deterministic" \
  "the issue contract carries an unresolved Human Gate" \
  "$(fxo_state "$G" get blocker_message)"
assert_eq "gate seq: the resume phase is the pre-staging gate phase" \
  "RESOLVE_HUMAN_GATES" "$(fxo_state "$G" get resume_phase)"
assert_fail_code "gate seq: STAGE is unreachable from the off-ramp" \
  ORCHESTRATOR_PHASE_MISMATCH fxo_orch "$G" stage
assert_eq "gate seq: the refused staging changed nothing" \
  "HUMAN_DECISION_REQUIRED" "$(fxo_phase "$G")"
assert_eq "gate seq: nothing was staged while the gate was open" \
  "" "$(git -C "$G" diff --cached --name-only)"

# A contract that ALREADY declares the gate settled continues through the
# existing resume path. (This is the corrected-contract shape, not an in-run
# settlement: an unresolved gate is never settled by editing the run's contract
# — that path is section 6a.)
regate "$G" gates-resolved
assert_eq "gate seq: a settled contract is visible to the parser" \
  "resolved" "$(gate_status "$G")"
assert_ok "gate seq: resume after the maintainer decision" fxo_orch "$G" resume
assert_eq "gate seq: resumed to RESOLVE_HUMAN_GATES" "RESOLVE_HUMAN_GATES" "$(fxo_phase "$G")"
assert_eq "gate seq: resume cleared the blocker" "" "$(fxo_state "$G" get blocker_code)"
assert_ok "gate seq: gates-resolved after the maintainer decision" fxo_orch "$G" gates-resolved
assert_eq "gate seq: STAGE becomes reachable" "STAGE" "$(fxo_phase "$G")"
assert_ok "gate seq: stage" fxo_orch "$G" stage
assert_eq "gate seq: staging is still manifest-derived" \
  ".claude/scripts/orchestrated.sh" "$(git -C "$G" diff --cached --name-only)"

# the settled gate is recorded as explicit evidence and reaches the PR body
assert_eq "gate seq: the gate record captures the maintainer decision" "resolved" \
  "$(jq -r '.status' "$(fxo_state_dir "$G")/records/human-gate.json")"
assert_eq "gate seq: the gate record is tied to the settled contract" \
  "$(fxo_state "$G" get contract_hash)" \
  "$(jq -r '.contract_hash' "$(fxo_state_dir "$G")/records/human-gate.json")"
fxo_orch "$G" verify-staged >/dev/null
fxo_orch "$G" commit >/dev/null
fxo_orch "$G" push >/dev/null
assert_ok "gate seq: create-pr after a settled gate" fxo_orch "$G" create-pr
assert_contains "gate seq: the PR body reports the resolved Human Gate" \
  "$(cat "$(fxo_state_dir "$G")/pr-body.md")" "| Human Gate resolution | resolved |"

# --- an already-resolved gate keeps the happy path
boot 35 "Resolved gate probe"
GR="$BOOT_WT"
fxo_set_verify PASS
regate "$GR" gates-resolved
run_capture fxo_orch "$GR" validate-contract
assert_eq "gate resolved: validate-contract succeeds" "0" "$RC"
assert_eq "gate resolved: the gate state is reported" "resolved" \
  "$(printf '%s' "$OUT" | jq -r '.human_gates')"
fxo_orch "$GR" begin-plan >/dev/null
fxo_orch "$GR" begin-implement >/dev/null
fxo_candidate "$GR"
fxo_orch "$GR" verify-worktree >/dev/null
fxo_orch "$GR" begin-review >/dev/null
fxo_orch "$GR" review-pass >/dev/null
assert_ok "gate resolved: gates-resolved continues to STAGE" fxo_orch "$GR" gates-resolved
assert_eq "gate resolved: -> STAGE" "STAGE" "$(fxo_phase "$GR")"

# --- malformed gate structure still fails closed at contract validation
for gm_variant in gates-malformed gates-none-unchecked; do
  boot 36 "Malformed gate probe"
  GM="$BOOT_WT"
  regate "$GM" "$gm_variant"
  run_capture fxo_orch "$GM" validate-contract
  assert_ne "gate structure: '$gm_variant' fails closed" "0" "$RC"
  assert_eq "gate structure: '$gm_variant' -> CONTRACT_CLARIFICATION_REQUIRED" \
    "CONTRACT_CLARIFICATION_REQUIRED" "$(fxo_phase "$GM")"
  assert_eq "gate structure: '$gm_variant' records CONTRACT_INVALID" \
    "CONTRACT_INVALID" "$(fxo_state "$GM" get blocker_code)"
done

# ========================================================================
# 6a. Maintainer Human Gate decisions (Issue #24, reopened scope)
# ========================================================================
#
# The initialised issue contract and state.json.contract_hash are run identity,
# so a gate the contract declares `unresolved` can never be settled by editing
# it. It is settled by an explicit maintainer decision record, written by an
# entry point the orchestrating model cannot reach and bound to this run's exact
# evidence. Without a valid approval, STAGE stays unreachable.

# hg_boot ISSUE TITLE — a run whose immutable contract declares an unresolved
# gate, driven to RESOLVE_HUMAN_GATES with complete verification and review
# evidence. Sets HG / HG_SD / HG_REC / HG_DEC.
hg_boot() {
  boot "$1" "$2"
  HG="$BOOT_WT"
  fxo_set_verify PASS
  regate "$HG" gates-unresolved
  fxo_orch "$HG" validate-contract >/dev/null
  fxo_orch "$HG" begin-plan >/dev/null
  fxo_orch "$HG" begin-implement >/dev/null
  fxo_candidate "$HG"
  fxo_orch "$HG" verify-worktree >/dev/null
  fxo_orch "$HG" begin-review >/dev/null
  fxo_orch "$HG" review-pass >/dev/null
  HG_SD="$(fxo_state_dir "$HG")"
  HG_REC="$HG_SD/records"
  HG_DEC="$(fxo_decision_path "$HG")"
}

# hg_refuse NAME — gates-resolved must fail closed on the unresolved-gate
# off-ramp, write no settlement evidence, and leave STAGE unreachable. Resumes
# afterwards so the next probe starts from the decision point again.
hg_refuse() {
  run_capture fxo_orch "$HG" gates-resolved
  assert_ne "$1: gates-resolved is refused" "0" "$RC"
  assert_eq "$1: -> HUMAN_DECISION_REQUIRED" "HUMAN_DECISION_REQUIRED" "$(fxo_phase "$HG")"
  assert_eq "$1: the blocker is HUMAN_GATE_UNRESOLVED" \
    "HUMAN_GATE_UNRESOLVED" "$(fxo_state "$HG" get blocker_code)"
  assert_file_absent "$1: no Human Gate settlement evidence was written" "$HG_REC/human-gate.json"
  fxo_orch "$HG" resume >/dev/null
}

# --- the decision point, the authority boundary, and a valid approval ----

hg_boot 40 "Maintainer gate approval probe"
HG_CONTRACT_BEFORE="$(cat "$HG_SD/issue-contract.md")"
HG_HASH_BEFORE="$(fxo_state "$HG" get contract_hash)"
HG_FP="$(jq -r '.fingerprint' "$HG_SD/reviewed-manifest.json")"

assert_eq "maintainer gate: the run reached the decision point" \
  "RESOLVE_HUMAN_GATES" "$(fxo_phase "$HG")"
assert_file_absent "maintainer gate: no decision record exists yet" "$HG_DEC"

# without a decision the gate is exactly what the contract says it is
run_capture fxo_orch "$HG" gates-resolved
assert_ne "maintainer gate: no decision refuses gates-resolved" "0" "$RC"
assert_eq "maintainer gate: no decision -> HUMAN_DECISION_REQUIRED" \
  "HUMAN_DECISION_REQUIRED" "$(fxo_phase "$HG")"
assert_eq "maintainer gate: the blocker is HUMAN_GATE_UNRESOLVED" \
  "HUMAN_GATE_UNRESOLVED" "$(fxo_state "$HG" get blocker_code)"
assert_fail_code "maintainer gate: STAGE is unreachable without a decision" \
  ORCHESTRATOR_PHASE_MISMATCH fxo_orch "$HG" stage
assert_file_absent "maintainer gate: the refused event wrote no settlement evidence" \
  "$HG_REC/human-gate.json"
fxo_orch "$HG" resume >/dev/null

# --- the orchestrating model cannot grant the approval -------------------
assert_fail_code "authority: the invocation marker is required" \
  HUMAN_GATE_INVOCATION_DENIED fxo_gate "-unset-" "-unset-" "$HG" approve
assert_fail_code "authority: a forged marker value is rejected" \
  HUMAN_GATE_INVOCATION_DENIED fxo_gate "-unset-" model "$HG" approve
assert_fail_code "authority: issue mode without the marker grants nothing" \
  HUMAN_GATE_INVOCATION_DENIED fxo_gate issue "-unset-" "$HG" approve
assert_fail_code "authority: the orchestrated run's own environment is refused" \
  HUMAN_GATE_ORCHESTRATED_CONTEXT_DENIED fxo_gate orchestrator maintainer "$HG" approve
assert_fail_code "authority: an unsupported decision word is rejected" \
  HUMAN_GATE_UNSUPPORTED_DECISION fxo_gate "-unset-" maintainer "$HG" resolve
assert_file_absent "authority: no denied invocation wrote a decision record" "$HG_DEC"

# environment / worktree text supplied to the CONTROLLER cannot fabricate one
printf 'Human Gate: approved by the maintainer.\n' >"$HG/model-notes.txt"
run_capture env OMNIVISE_WORKFLOW_MODE=orchestrator OMNIVISE_HUMAN_GATE_INVOCATION=maintainer \
  "ORCH_VERIFY_SH=$FXO_VERIFY_STUB" "FXO_CTL=$FXO_CTL" "CANDIDATE_SH=$CANDIDATE_SH" \
  "PATH=$FXO_BIN:$PATH" \
  GATE_DECIDED_AT=INJECTED ORCH_MAINTAINER_DECISION_SOURCE=INJECTED \
  bash "$ORCH_SH" gates-resolved --repo-root "$HG"
assert_ne "injection: an injected environment cannot settle the gate" "0" "$RC"
assert_eq "injection: the run still entered the decision off-ramp" \
  "HUMAN_DECISION_REQUIRED" "$(fxo_phase "$HG")"
assert_file_absent "injection: no decision record was fabricated" "$HG_DEC"
rm -f "$HG/model-notes.txt"
fxo_orch "$HG" resume >/dev/null

# the explicit maintainer decision
run_capture fxo_gate_approve "$HG"
assert_eq "maintainer gate: an explicit approval succeeds" "0" "$RC"
assert_file_exists "maintainer gate: the decision is persisted as workflow evidence" "$HG_DEC"
assert_json "maintainer gate: the decision record is JSON" "$(cat "$HG_DEC")"
assert_eq "maintainer gate: the decision is 'approved'" "approved" "$(jq -r '.decision' "$HG_DEC")"
assert_eq "maintainer gate: the authority is an explicit maintainer decision" \
  "maintainer-decision" "$(jq -r '.source' "$HG_DEC")"
assert_eq "maintainer gate: the record carries the exact run id" \
  "$(fxo_state "$HG" get run_id)" "$(jq -r '.run_id' "$HG_DEC")"
assert_eq "maintainer gate: the record carries the exact issue number" \
  "40" "$(jq -r '.issue_number' "$HG_DEC")"
assert_eq "maintainer gate: the record carries the recorded contract hash" \
  "$HG_HASH_BEFORE" "$(jq -r '.contract_hash' "$HG_DEC")"
assert_eq "maintainer gate: the record carries the reviewed fingerprint" \
  "$HG_FP" "$(jq -r '.reviewed_fingerprint' "$HG_DEC")"
assert_eq "maintainer gate: the record carries the VERIFY_WORKTREE identity" \
  "PASS|$HG_FP" \
  "$(jq -r '.verify_worktree_result + "|" + .verify_worktree_fingerprint' "$HG_DEC")"
assert_eq "maintainer gate: the record carries the review verdict and counts" \
  "PASS|0|0" \
  "$(jq -r '.review_verdict + "|" + (.review_critical|tostring) + "|" + (.review_major|tostring)' "$HG_DEC")"
assert_eq "maintainer gate: the decision record persists only deterministic fields" \
  "contract_hash,decision,issue_number,recorded_at,review_critical,review_major,review_verdict,reviewed_fingerprint,run_id,schema_version,source,verify_worktree_fingerprint,verify_worktree_result" \
  "$(jq -r '[keys[]] | join(",")' "$HG_DEC")"

# --- the run's identity is untouched by the decision ---------------------
assert_eq "immutability: the stored issue contract is byte-identical after approval" \
  "$HG_CONTRACT_BEFORE" "$(cat "$HG_SD/issue-contract.md")"
assert_eq "immutability: state.json.contract_hash is unchanged after approval" \
  "$HG_HASH_BEFORE" "$(fxo_state "$HG" get contract_hash)"
assert_eq "immutability: the contract parser still reports the gate as unresolved" \
  "unresolved" "$(gate_status "$HG")"

# --- a valid approval permits the existing RESOLVE_HUMAN_GATES -> STAGE ---
run_capture fxo_orch "$HG" gates-resolved
assert_eq "maintainer gate: gates-resolved succeeds after a valid approval" "0" "$RC"
assert_eq "maintainer gate: -> STAGE" "STAGE" "$(fxo_phase "$HG")"
assert_eq "maintainer gate: the event reports the maintainer approval" \
  "maintainer-approved" "$(printf '%s' "$OUT" | jq -r '.human_gates')"
assert_eq "evidence: the settlement record distinguishes a maintainer approval" \
  "maintainer-approved" "$(jq -r '.status' "$HG_REC/human-gate.json")"
assert_eq "evidence: the settlement record's authority is the maintainer decision" \
  "maintainer-decision" "$(jq -r '.source' "$HG_REC/human-gate.json")"
assert_eq "evidence: the settlement record is tied to the recorded contract" \
  "$HG_HASH_BEFORE" "$(jq -r '.contract_hash' "$HG_REC/human-gate.json")"
assert_eq "evidence: the settlement record is tied to this run and candidate" \
  "$(fxo_state "$HG" get run_id)|40|$HG_FP" \
  "$(jq -r '.run_id + "|" + (.issue_number|tostring) + "|" + .reviewed_fingerprint' "$HG_REC/human-gate.json")"
assert_eq "evidence: the settlement record carries the decision timestamp" \
  "$(jq -r '.recorded_at' "$HG_DEC")" "$(jq -r '.decided_at' "$HG_REC/human-gate.json")"
assert_eq "immutability: the contract is still byte-identical after gates-resolved" \
  "$HG_CONTRACT_BEFORE" "$(cat "$HG_SD/issue-contract.md")"
assert_eq "immutability: contract_hash is still unchanged after gates-resolved" \
  "$HG_HASH_BEFORE" "$(fxo_state "$HG" get contract_hash)"

# --- the approved gate reaches deterministic PR evidence (Issue #28) ------
fxo_orch "$HG" stage >/dev/null
fxo_orch "$HG" verify-staged >/dev/null
fxo_orch "$HG" commit >/dev/null
fxo_orch "$HG" push >/dev/null
: >"$FXO_GH_LOG"
assert_ok "maintainer gate: create-pr after a maintainer-approved gate" fxo_orch "$HG" create-pr
HG_BODY="$(cat "$HG_SD/pr-body.md")"
assert_contains "pr evidence: the maintainer-approved gate is reported as such" \
  "$HG_BODY" "| Human Gate resolution | maintainer-approved |"
assert_contains "pr evidence: the PR body carries the unchanged contract hash" \
  "$HG_BODY" "| Contract hash | $HG_HASH_BEFORE |"
assert_contains "pr evidence: the PR body carries the reviewed fingerprint" \
  "$HG_BODY" "| Reviewed candidate fingerprint | $HG_FP |"
assert_eq "immutability: the contract survived the whole run unchanged" \
  "$HG_CONTRACT_BEFORE" "$(cat "$HG_SD/issue-contract.md")"

# --- no orchestration event can produce a decision record ----------------

hg_boot 41 "Event grammar probe"
for ev in status validate-contract begin-plan begin-implement verify-worktree \
          begin-review review-pass review-changes-required review-reassess \
          reassess-complete gates-resolved stage verify-staged commit push \
          create-pr resume; do
  fxo_orch "$HG" "$ev" >/dev/null 2>&1 || true
done
assert_file_absent "event grammar: no orchestration event created a decision record" "$HG_DEC"
assert_file_absent "event grammar: no orchestration event settled the gate" "$HG_REC/human-gate.json"
assert_ne "event grammar: STAGE was never reached" "STAGE" "$(fxo_phase "$HG")"
assert_eq "event grammar: nothing was staged" "" "$(git -C "$HG" diff --cached --name-only)"

# --- explicit rejection ---------------------------------------------------

hg_boot 42 "Maintainer gate rejection probe"
assert_ok "rejection: an explicit rejection is accepted" fxo_gate_reject "$HG"
assert_eq "rejection: the decision is 'rejected'" "rejected" "$(jq -r '.decision' "$HG_DEC")"
assert_eq "rejection: the rejection is bound to the run" \
  "$(fxo_state "$HG" get run_id)" "$(jq -r '.run_id' "$HG_DEC")"

run_capture fxo_orch "$HG" gates-resolved
assert_ne "rejection: gates-resolved is refused" "0" "$RC"
assert_eq "rejection: -> MANUAL_REVIEW_REQUIRED" "MANUAL_REVIEW_REQUIRED" "$(fxo_phase "$HG")"
assert_eq "rejection: the blocker names the maintainer rejection" \
  "HUMAN_GATE_REJECTED" "$(fxo_state "$HG" get blocker_code)"
assert_eq "rejection: the blocker message is deterministic" \
  "the maintainer rejected the Human Gate decision" "$(fxo_state "$HG" get blocker_message)"
assert_eq "rejection: the resume phase is the gate decision point" \
  "RESOLVE_HUMAN_GATES" "$(fxo_state "$HG" get resume_phase)"
assert_fail_code "rejection: STAGE is unreachable" ORCHESTRATOR_PHASE_MISMATCH \
  fxo_orch "$HG" stage
assert_file_absent "rejection: no settlement evidence was written" "$HG_REC/human-gate.json"
assert_eq "rejection: nothing was staged" "" "$(git -C "$HG" diff --cached --name-only)"

# a rejection is not undone by resuming
fxo_orch "$HG" resume >/dev/null
run_capture fxo_orch "$HG" gates-resolved
assert_eq "rejection: resuming does not clear the rejection" \
  "MANUAL_REVIEW_REQUIRED" "$(fxo_phase "$HG")"

# only another explicit maintainer decision changes it
fxo_orch "$HG" resume >/dev/null
assert_ok "rejection: the maintainer may explicitly approve afterwards" fxo_gate_approve "$HG"
assert_ok "rejection: the replaced decision permits STAGE" fxo_orch "$HG" gates-resolved
assert_eq "rejection: -> STAGE after the explicit approval" "STAGE" "$(fxo_phase "$HG")"

# --- stale, cross-run and tampered decisions fail closed -----------------

hg_boot 43 "Stale decision probe"
fxo_gate_approve "$HG" >/dev/null
cp "$HG_DEC" "$HG_DEC.bak"
cp "$HG_REC/verify-worktree.json" "$HG_REC/verify-worktree.json.bak"
cp "$HG_REC/review.json" "$HG_REC/review.json.bak"

# hg_tamper NAME JQ_FILTER — rewrite one field of the decision record and prove
# gates-resolved fails closed on it.
hg_tamper() {
  jq -c "$2" "$HG_DEC.bak" >"$HG_DEC"
  hg_refuse "$1"
  cp "$HG_DEC.bak" "$HG_DEC"
}

hg_tamper "stale: another run id" '.run_id = "00000000-0000-0000-0000-0000000000ff"'
hg_tamper "stale: another issue number" '.issue_number = 999'
hg_tamper "stale: another contract hash" '.contract_hash = "0000000000000000000000000000000000000000000000000000000000000fee"'
hg_tamper "stale: another reviewed candidate" '.reviewed_fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000bad"'
hg_tamper "stale: a non-passing VERIFY_WORKTREE claim" '.verify_worktree_result = "FAIL"'
hg_tamper "stale: a VERIFY_WORKTREE fingerprint for another candidate" '.verify_worktree_fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000fad"'
hg_tamper "stale: a non-passing review claim" '.review_verdict = "FAIL"'
hg_tamper "stale: a claimed Critical finding" '.review_critical = 3'
hg_tamper "stale: a claimed Major finding" '.review_major = 2'
hg_tamper "forged: a non-maintainer authority" '.source = "orchestration-event"'
hg_tamper "forged: an unsupported schema version" '.schema_version = 2'
hg_tamper "forged: an unrecognised decision word" '.decision = "APPROVED"'
hg_tamper "forged: a decision record with no decision" 'del(.decision)'

# Issue #24 correction round 1 (MINOR-1): the decision record is an integrity
# boundary, so its JSON TYPES are authoritative too. A field whose rendered text
# would compare equal is still rejected when it is the wrong type.
hg_tamper "typed: a stringified schema version" '.schema_version |= tostring'
hg_tamper "typed: a stringified issue number" '.issue_number |= tostring'
hg_tamper "typed: a stringified Critical count" '.review_critical |= tostring'
hg_tamper "typed: a stringified Major count" '.review_major |= tostring'
hg_tamper "typed: a null run id" '.run_id = null'
hg_tamper "typed: an empty contract hash" '.contract_hash = ""'
hg_tamper "typed: a missing decision timestamp" 'del(.recorded_at)'

printf 'not json at all\n' >"$HG_DEC"
hg_refuse "malformed: a decision record that is not JSON"
cp "$HG_DEC.bak" "$HG_DEC"

rm -f "$HG_DEC"
hg_refuse "missing: no decision record at all"
cp "$HG_DEC.bak" "$HG_DEC"

# the approval is also re-checked against the LIVE evidence, so evidence that
# changed after the decision fails closed too
hg_live() {
  jq -c "$3" "$2.bak" >"$2"
  hg_refuse "$1"
  cp "$2.bak" "$2"
}
hg_live "live: VERIFY_WORKTREE no longer passes" "$HG_REC/verify-worktree.json" '.result = "FAIL"'
hg_live "live: the verified candidate changed" "$HG_REC/verify-worktree.json" \
  '.candidate.fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000fad"'
hg_live "live: the review no longer clears Critical" "$HG_REC/review.json" '.critical = 1'
hg_live "live: the review describes another candidate" "$HG_REC/review.json" \
  '.reviewed_fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000bad"'

# Issue #24 correction round 1 (MAJOR-1): the live evidence must also PROVE it
# belongs to this run and this issue. Each case below rewrites only provenance —
# the candidate fingerprint, verdict and counts stay exactly as the untampered
# approval bound them — so a refusal can only come from the provenance check.
HG_WT_FP_BEFORE="$(jq -r '.candidate.fingerprint' "$HG_REC/verify-worktree.json")"
HG_RV_FP_BEFORE="$(jq -r '.reviewed_fingerprint' "$HG_REC/review.json")"

# hg_prov NAME FILE JQ_FILTER — like hg_live, but additionally asserts that the
# candidate fingerprint the tampered record carries is unchanged.
hg_prov() {
  jq -c "$3" "$2.bak" >"$2"
  assert_eq "$1: the candidate fingerprints are untouched" \
    "$HG_WT_FP_BEFORE|$HG_RV_FP_BEFORE" \
    "$(jq -r '.candidate.fingerprint' "$HG_REC/verify-worktree.json")|$(jq -r '.reviewed_fingerprint' "$HG_REC/review.json")"
  hg_refuse "$1"
  cp "$2.bak" "$2"
}

hg_prov "provenance: a PASS VERIFY_WORKTREE from another run" \
  "$HG_REC/verify-worktree.json" '.run_id = "00000000-0000-0000-0000-0000000000ff"'
hg_prov "provenance: a PASS VERIFY_WORKTREE for another issue" \
  "$HG_REC/verify-worktree.json" '.issue_number = 999'
hg_prov "provenance: accepted review evidence from another run" \
  "$HG_REC/review.json" '.run_id = "00000000-0000-0000-0000-0000000000ff"'
hg_prov "provenance: accepted review evidence for another issue" \
  "$HG_REC/review.json" '.issue_number = 999'

# missing or wrongly typed provenance is not "no opinion" — it fails closed
hg_live "provenance: VERIFY_WORKTREE with no run id" "$HG_REC/verify-worktree.json" 'del(.run_id)'
hg_live "provenance: VERIFY_WORKTREE with a null run id" "$HG_REC/verify-worktree.json" '.run_id = null'
hg_live "provenance: VERIFY_WORKTREE with no issue number" "$HG_REC/verify-worktree.json" 'del(.issue_number)'
hg_live "provenance: a stringified VERIFY_WORKTREE issue number" \
  "$HG_REC/verify-worktree.json" '.issue_number |= tostring'
hg_live "provenance: review evidence with no run id" "$HG_REC/review.json" 'del(.run_id)'
hg_live "provenance: a stringified review issue number" "$HG_REC/review.json" '.issue_number |= tostring'

rm -f "$HG_REC/verify-worktree.json"
hg_refuse "live: the VERIFY_WORKTREE record is gone"
cp "$HG_REC/verify-worktree.json.bak" "$HG_REC/verify-worktree.json"
rm -f "$HG_REC/review.json"
hg_refuse "live: the review record is gone"
cp "$HG_REC/review.json.bak" "$HG_REC/review.json"

# the restored, untampered set still reaches STAGE, so every refusal above was
# caused by the tampering and nothing else
assert_ok "stale: the restored decision still permits STAGE" fxo_orch "$HG" gates-resolved
assert_eq "stale: -> STAGE" "STAGE" "$(fxo_phase "$HG")"

# --- approval prerequisites are enforced where the decision is taken -----

hg_boot 44 "Approval prerequisite probe"
cp "$HG_REC/verify-worktree.json" "$HG_REC/verify-worktree.json.bak"
cp "$HG_REC/review.json" "$HG_REC/review.json.bak"
cp "$HG_SD/reviewed-manifest.json" "$HG_SD/reviewed-manifest.json.bak"

# hg_pre NAME CODE FILE JQ_FILTER — a prerequisite violation refuses the approval
hg_pre() {
  jq -c "$4" "$3.bak" >"$3"
  assert_fail_code "$1" "$2" fxo_gate_approve "$HG"
  cp "$3.bak" "$3"
}

hg_pre "prerequisite: VERIFY_WORKTREE must pass" HUMAN_GATE_VERIFICATION_NOT_PASSING \
  "$HG_REC/verify-worktree.json" '.result = "FAIL"'
hg_pre "prerequisite: the verified candidate must be the reviewed candidate" \
  HUMAN_GATE_EVIDENCE_STALE "$HG_REC/verify-worktree.json" \
  '.candidate.fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000fad"'
hg_pre "prerequisite: the review must describe the reviewed candidate" \
  HUMAN_GATE_EVIDENCE_STALE "$HG_REC/review.json" \
  '.reviewed_fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000bad"'
hg_pre "prerequisite: the review verdict must be PASS" HUMAN_GATE_REVIEW_NOT_ACCEPTED \
  "$HG_REC/review.json" '.verdict = "FAIL"'
hg_pre "prerequisite: Critical must be 0" HUMAN_GATE_REVIEW_NOT_ACCEPTED \
  "$HG_REC/review.json" '.critical = 2'
hg_pre "prerequisite: Major must be 0" HUMAN_GATE_REVIEW_NOT_ACCEPTED \
  "$HG_REC/review.json" '.major = 1'

# Issue #24 correction round 1 (MAJOR-1): the maintainer entry point refuses the
# approval for the same provenance reasons, with a code that says so. Only the
# run/issue fields are rewritten; fingerprints, verdict and counts stay valid.
hg_pre "provenance: VERIFY_WORKTREE must belong to this run" HUMAN_GATE_EVIDENCE_STALE \
  "$HG_REC/verify-worktree.json" '.run_id = "00000000-0000-0000-0000-0000000000ff"'
hg_pre "provenance: VERIFY_WORKTREE must belong to this issue" HUMAN_GATE_EVIDENCE_STALE \
  "$HG_REC/verify-worktree.json" '.issue_number = 999'
hg_pre "provenance: the review must belong to this run" HUMAN_GATE_EVIDENCE_STALE \
  "$HG_REC/review.json" '.run_id = "00000000-0000-0000-0000-0000000000ff"'
hg_pre "provenance: the review must belong to this issue" HUMAN_GATE_EVIDENCE_STALE \
  "$HG_REC/review.json" '.issue_number = 999'
hg_pre "provenance: absent VERIFY_WORKTREE provenance fails closed" HUMAN_GATE_EVIDENCE_MISSING \
  "$HG_REC/verify-worktree.json" 'del(.run_id)'
hg_pre "provenance: absent review provenance fails closed" HUMAN_GATE_EVIDENCE_MISSING \
  "$HG_REC/review.json" 'del(.issue_number)'
hg_pre "provenance: a stringified issue number is not the issue number" HUMAN_GATE_EVIDENCE_MISSING \
  "$HG_REC/review.json" '.issue_number |= tostring'

for missing in "$HG_REC/verify-worktree.json" "$HG_REC/review.json" "$HG_SD/reviewed-manifest.json"; do
  mv "$missing" "$missing.hidden"
  assert_fail_code "prerequisite: missing evidence refuses the approval ($(basename "$missing"))" \
    HUMAN_GATE_EVIDENCE_MISSING fxo_gate_approve "$HG"
  mv "$missing.hidden" "$missing"
done
assert_file_absent "prerequisite: no refused approval wrote a decision record" "$HG_DEC"

# a decision taken against a drifted contract is refused
cp "$HG_SD/issue-contract.md" "$HG_SD/issue-contract.bak"
printf '\ndrifted\n' >>"$HG_SD/issue-contract.md"
assert_fail_code "prerequisite: a drifted contract refuses the approval" \
  HUMAN_GATE_CONTRACT_HASH_MISMATCH fxo_gate_approve "$HG"
cp "$HG_SD/issue-contract.bak" "$HG_SD/issue-contract.md"
assert_ok "prerequisite: the restored contract permits the approval" fxo_gate_approve "$HG"

# --- the decision is bound to the decision point and to a pending gate ---

boot 45 "Decision point probe"
DP="$BOOT_WT"
fxo_set_verify PASS
regate "$DP" gates-unresolved
assert_fail_code "decision point: FETCH_ISSUE is not the gate decision point" \
  HUMAN_GATE_PHASE_MISMATCH fxo_gate "-unset-" maintainer "$DP" approve
fxo_orch "$DP" validate-contract >/dev/null
fxo_orch "$DP" begin-plan >/dev/null
fxo_orch "$DP" begin-implement >/dev/null
fxo_candidate "$DP"
fxo_orch "$DP" verify-worktree >/dev/null
fxo_orch "$DP" begin-review >/dev/null
assert_fail_code "decision point: REVIEW is not the gate decision point" \
  HUMAN_GATE_PHASE_MISMATCH fxo_gate "-unset-" maintainer "$DP" approve
assert_file_absent "decision point: no premature decision record exists" "$(fxo_decision_path "$DP")"
fxo_orch "$DP" review-pass >/dev/null
assert_ok "decision point: RESOLVE_HUMAN_GATES accepts the decision" \
  fxo_gate "-unset-" maintainer "$DP" approve

boot 46 "No pending gate probe"
NP="$BOOT_WT"
fxo_set_verify PASS
fxo_drive_to_review "$NP"
fxo_orch "$NP" review-pass >/dev/null
assert_fail_code "decision point: a contract declaring no gate has nothing to decide" \
  HUMAN_GATE_NOT_PENDING fxo_gate "-unset-" maintainer "$NP" approve
assert_file_absent "decision point: no decision record for a gateless contract" \
  "$(fxo_decision_path "$NP")"
assert_ok "decision point: the gateless happy path is unchanged" fxo_orch "$NP" gates-resolved
assert_eq "decision point: -> STAGE" "STAGE" "$(fxo_phase "$NP")"
assert_eq "decision point: the settlement record still reports 'none'" \
  "none" "$(jq -r '.status' "$(fxo_state_dir "$NP")/records/human-gate.json")"

# ========================================================================
# 6b. PR evidence fails closed through the controller (Issue #28)
# ========================================================================
#
# The lifecycle suite covers each individual evidence refusal; here the point is
# that an incomplete evidence set reaching the CONTROLLER produces no pull
# request, no recorded PR data, and a deterministic off-ramp.

boot 37 "PR evidence fail-closed probe"
FC="$BOOT_WT"
fxo_set_verify PASS
fxo_drive_to_review "$FC"
fxo_orch "$FC" review-pass >/dev/null
fxo_orch "$FC" gates-resolved >/dev/null
fxo_orch "$FC" stage >/dev/null
fxo_orch "$FC" verify-staged >/dev/null
fxo_orch "$FC" commit >/dev/null
fxo_orch "$FC" push >/dev/null
rm -f "$(fxo_state_dir "$FC")/records/review.json"

: >"$FXO_GH_LOG"
run_capture fxo_orch "$FC" create-pr
assert_ne "pr fail-closed: create-pr exits non-zero without review evidence" "0" "$RC"
assert_not_contains "pr fail-closed: no pull request was created" "$(cat "$FXO_GH_LOG")" "pr create"
assert_file_absent "pr fail-closed: no PR body was written" \
  "$(fxo_state_dir "$FC")/pr-body.md"
assert_eq "pr fail-closed: no PR number was recorded" "" "$(fxo_state "$FC" get pr_number)"
assert_eq "pr fail-closed: no PR URL was recorded" "" "$(fxo_state "$FC" get pr_url)"
assert_eq "pr fail-closed: the run entered the deterministic failure off-ramp" \
  "FAILED" "$(fxo_phase "$FC")"
assert_eq "pr fail-closed: the blocker is recorded" \
  "LIFECYCLE_FAILED" "$(fxo_state "$FC" get blocker_code)"
assert_eq "pr fail-closed: PR_READY_FOR_HUMAN_REVIEW was never reached" \
  "FAILED" "$(fxo_phase "$FC")"

# ========================================================================
# 7. Phase gating and grammar
# ========================================================================

boot 34 "Gating probe"
P="$BOOT_WT"
for ev in begin-plan begin-implement verify-worktree begin-review review-pass \
          review-changes-required review-reassess reassess-complete gates-resolved \
          stage verify-staged commit push create-pr; do
  assert_fail_code "gating: '$ev' is refused in FETCH_ISSUE" ORCHESTRATOR_PHASE_MISMATCH \
    fxo_orch "$P" "$ev"
done
assert_eq "gating: refused events never changed the phase" "FETCH_ISSUE" "$(fxo_phase "$P")"
assert_fail_code "grammar: an unknown event is rejected" ORCHESTRATOR_USAGE fxo_orch "$P" nuke
assert_fail_code "grammar: an unknown option is rejected" ORCHESTRATOR_USAGE \
  fxo_orch "$P" status --exec "rm -rf /"
assert_ok "grammar: status is always available" fxo_orch "$P" status
assert_json "grammar: status prints the state document" "$(fxo_orch "$P" status)"

# --- mode authority
assert_fail_code "authority: issue mode cannot drive orchestration" ORCHESTRATOR_MODE_REQUIRED \
  fxo_orch_mode issue "$P" status
assert_fail_code "authority: framework-maintenance cannot drive orchestration" ORCHESTRATOR_MODE_REQUIRED \
  fxo_orch_mode framework-maintenance "$P" status
assert_fail_code "authority: an unset mode cannot drive orchestration" ORCHESTRATOR_MODE_REQUIRED \
  fxo_orch_mode "-unset-" "$P" status

# --- state must exist and validate
NOSTATE="$(fxo_primary "$(fxo_origin)")"
assert_fail_code "state: orchestration requires initialised workflow state" ORCHESTRATOR_STATE_INVALID \
  fxo_orch "$NOSTATE" status

# ========================================================================
# 8. Isolation
# ========================================================================

assert_eq "orchestrator isolation: real repo index unchanged" \
  "" "$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"
