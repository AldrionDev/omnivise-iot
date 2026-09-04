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

# ========================================================================
# 1. Happy path, phase by phase
# ========================================================================

boot 19 "Add orchestrate issue workflow"
H="$BOOT_WT"
fxo_set_verify PASS

assert_eq "happy: bootstrap phase" "FETCH_ISSUE" "$(fxo_phase "$H")"

assert_ok   "happy: validate-contract" fxo_orch "$H" validate-contract
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
assert_file_absent "happy: no reviewed manifest exists before review PASS" "$H_SD/reviewed-manifest.json"

run_capture fxo_orch "$H" review-pass
assert_eq   "happy: -> RESOLVE_HUMAN_GATES" "RESOLVE_HUMAN_GATES" "$(fxo_phase "$H")"
assert_file_exists "happy: reviewed manifest captured before staging" "$H_SD/reviewed-manifest.json"
assert_eq   "happy: reviewed manifest matches the candidate fingerprint" \
  "$(bash "$CANDIDATE_SH" --repo-root "$H" fingerprint)" \
  "$(jq -r '.fingerprint' "$H_SD/reviewed-manifest.json")"
assert_eq   "happy: workflow evidence is not a candidate file" \
  "1" "$(bash "$CANDIDATE_SH" --repo-root "$H" list | jq 'length')"

assert_ok "happy: gates-resolved (contract declares None)" fxo_orch "$H" gates-resolved
assert_eq "happy: -> STAGE" "STAGE" "$(fxo_phase "$H")"
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

# --- an unresolved human gate fails closed
boot 30 "Human gate probe"
G="$BOOT_WT"
G_GATED="$(fx_contract gates-unresolved)"
G_SD="$(fxo_state_dir "$G")"
cp "$G_GATED" "$G_SD/issue-contract.md"
# realign the recorded hash so the gate, not the hash, is what blocks
G_NEWSTATE="$(jq -c --arg h "$(bash "$CONTRACT_SH" hash "$G_GATED")" '.contract_hash = $h' "$G_SD/state.json")"
printf '%s\n' "$G_NEWSTATE" >"$G_SD/state.json"
run_capture fxo_orch "$G" validate-contract
assert_eq "offramp: unresolved human gate -> HUMAN_DECISION_REQUIRED" \
  "HUMAN_DECISION_REQUIRED" "$(fxo_phase "$G")"
assert_eq "offramp: the blocker is HUMAN_GATE_UNRESOLVED" \
  "HUMAN_GATE_UNRESOLVED" "$(fxo_state "$G" get blocker_code)"

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
# 6. Phase gating and grammar
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
# 7. Isolation
# ========================================================================

assert_eq "orchestrator isolation: real repo index unchanged" \
  "" "$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"
