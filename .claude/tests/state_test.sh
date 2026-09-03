#!/usr/bin/env bash
# state_test.sh — workflow-state.sh

suite "workflow-state"

# --- init / run id -------------------------------------------------------

R="$(fx_repo_new)"
BC="$(git -C "$R" rev-parse HEAD)"

assert_fail_code "init requires a caller-supplied run id" WORKFLOW_STATE_RUN_ID_REQUIRED \
  fx_state "$R" init --issue-number 15 --feature-branch f/15 --base-branch main \
    --base-commit "$BC" --contract-hash h --allowed-path 'a/**' --protected-path 'b/**'

CLAUDE_SESSION_ID="bogus-session" fx_state_init "$R" "run-explicit-42"
assert_eq "init persists the caller run id verbatim" "run-explicit-42" "$(fx_state "$R" get run_id)"
assert_eq "init starts in FETCH_ISSUE" "FETCH_ISSUE" "$(fx_state "$R" get phase)"
assert_ok "fresh state validates" fx_state "$R" validate

# no script consults CLAUDE_SESSION_ID
assert_not_contains "no script reads CLAUDE_SESSION_ID" \
  "$(grep -rn 'CLAUDE_SESSION_ID\|CLAUDE_SESSION\|SESSION_ID' "$SCRIPTS_DIR" || true)" "CLAUDE_SESSION"

run_capture fx_state "$R" status
assert_json "status emits valid JSON" "$OUT"

# --- transitions -------------------------------------------------------

RT="$(fx_repo_new)"; fx_state_init "$RT"
for pair in \
  "FETCH_ISSUE VALIDATE_ISSUE" "VALIDATE_ISSUE PLAN" "PLAN IMPLEMENT" \
  "IMPLEMENT VERIFY_WORKTREE" "VERIFY_WORKTREE REVIEW" "REVIEW RESOLVE_HUMAN_GATES" \
  "RESOLVE_HUMAN_GATES STAGE" "STAGE VERIFY_STAGED" "VERIFY_STAGED COMMIT" \
  "COMMIT PUSH" "PUSH CREATE_PR" "CREATE_PR PR_READY_FOR_HUMAN_REVIEW"; do
  set -- $pair
  run_capture fx_state "$RT" transition "$2"
  assert_eq "transition $1 -> $2" "$2" "$OUT"
done

# EVERY allowed edge in workflow-state.sh legal_transition() is exercised here.
# Keep this list in lock-step with the explicit transition table.
for edge in \
  "FETCH_ISSUE VALIDATE_ISSUE" \
  "VALIDATE_ISSUE PLAN" \
  "PLAN IMPLEMENT" \
  "IMPLEMENT VERIFY_WORKTREE" \
  "VERIFY_WORKTREE REVIEW" \
  "VERIFY_WORKTREE REPAIR_IMPLEMENTATION" \
  "REPAIR_IMPLEMENTATION VERIFY_WORKTREE" \
  "REVIEW REASSESS_REVIEW" \
  "REVIEW FIX" \
  "REVIEW RESOLVE_HUMAN_GATES" \
  "REASSESS_REVIEW REVIEW" \
  "FIX VERIFY_WORKTREE" \
  "RESOLVE_HUMAN_GATES STAGE" \
  "STAGE VERIFY_STAGED" \
  "VERIFY_STAGED COMMIT" \
  "VERIFY_STAGED FIX" \
  "COMMIT PUSH" \
  "PUSH CREATE_PR" \
  "CREATE_PR PR_READY_FOR_HUMAN_REVIEW"; do
  set -- $edge
  RE="$(fx_repo_new)"; fx_state_init "$RE"; fx_state_reach "$RE" "$1"
  assert_eq "reached start phase $1" "$1" "$(fx_state "$RE" get phase)"
  run_capture fx_state "$RE" transition "$2"
  assert_eq "allowed transition $1 -> $2" "$2" "$OUT"
done

# --- off-ramp mechanics, one representative per supported class ---------

for offramp in CONTRACT_CLARIFICATION_REQUIRED HUMAN_DECISION_REQUIRED \
               MANUAL_REVIEW_REQUIRED WAITING_ENVIRONMENT; do
  RO="$(fx_repo_new)"; fx_state_init "$RO"; fx_state_reach "$RO" IMPLEMENT
  # entry from a normal phase
  assert_ok  "$offramp: entered from a normal phase" fx_state "$RO" transition "$offramp"
  assert_eq  "$offramp: resume_phase recorded" "IMPLEMENT" "$(fx_state "$RO" get resume_phase)"
  # may not jump forward
  assert_fail_code "$offramp: cannot jump forward" WORKFLOW_STATE_ILLEGAL_TRANSITION \
    fx_state "$RO" transition VERIFY_WORKTREE
  # returns only to the paused phase
  assert_ok  "$offramp: returns to resume phase" fx_state "$RO" transition IMPLEMENT
  assert_eq  "$offramp: resume cleared on return" "" "$(fx_state "$RO" get resume_phase)"
  # ...and may instead go to FAILED (terminal)
  RO2="$(fx_repo_new)"; fx_state_init "$RO2"; fx_state_reach "$RO2" IMPLEMENT
  fx_state "$RO2" transition "$offramp" >/dev/null
  assert_ok  "$offramp: may transition to FAILED" fx_state "$RO2" transition FAILED
  assert_fail_code "$offramp -> FAILED is terminal" WORKFLOW_STATE_ILLEGAL_TRANSITION \
    fx_state "$RO2" transition IMPLEMENT
done

# terminal PR_READY_FOR_HUMAN_REVIEW has no forward transition
RPT="$(fx_repo_new)"; fx_state_init "$RPT"; fx_state_reach "$RPT" PR_READY_FOR_HUMAN_REVIEW
assert_fail_code "PR_READY_FOR_HUMAN_REVIEW has no forward transition" WORKFLOW_STATE_ILLEGAL_TRANSITION \
  fx_state "$RPT" transition FETCH_ISSUE

# --- illegal transitions leave state byte-identical --------------------

RI="$(fx_repo_new)"; fx_state_init "$RI"
SF="$(fx_state_file "$RI")"
before="$(sha256sum "$SF" | awk '{print $1}')"
assert_fail_code "FETCH_ISSUE -> COMMIT rejected" WORKFLOW_STATE_ILLEGAL_TRANSITION fx_state "$RI" transition COMMIT
assert_fail_code "unknown phase rejected"         WORKFLOW_STATE_ILLEGAL_TRANSITION fx_state "$RI" transition CREATE_WORKTREE
after="$(sha256sum "$SF" | awk '{print $1}')"
assert_eq "illegal transition left state byte-identical" "$before" "$after"

RF="$(fx_repo_new)"; fx_state_init "$RF"; fx_state "$RF" transition FAILED >/dev/null
assert_fail_code "FAILED is terminal" WORKFLOW_STATE_ILLEGAL_TRANSITION fx_state "$RF" transition PLAN

# --- corrupt / unsupported state fails closed -------------------------

RC="$(fx_repo_new)"; fx_state_init "$RC"; SFC="$(fx_state_file "$RC")"
printf 'not json {{{\n' > "$SFC"
assert_fail_code "corrupt JSON fails closed" WORKFLOW_STATE_INVALID fx_state "$RC" validate
assert_contains "corrupt state file not recreated" "$(cat "$SFC")" "not json"

RS="$(fx_repo_new)"; fx_state_init "$RS"; SFS="$(fx_state_file "$RS")"
jq '.schema_version = 2' "$SFS" > "$SFS.tmp" && mv "$SFS.tmp" "$SFS"
assert_fail_code "unsupported schema fails closed" WORKFLOW_STATE_UNSUPPORTED_SCHEMA fx_state "$RS" validate

RM="$(fx_repo_new)"; fx_state_init "$RM"; SFM="$(fx_state_file "$RM")"
jq 'del(.base_commit)' "$SFM" > "$SFM.tmp" && mv "$SFM.tmp" "$SFM"
assert_fail_code "missing required field fails closed" WORKFLOW_STATE_INVALID fx_state "$RM" validate

# --- counters ---------------------------------------------------------

RK="$(fx_repo_new)"; fx_state_init "$RK"
assert_eq "impl_repair_attempts inc -> 1" "1" "$(fx_state "$RK" counter impl_repair_attempts inc)"
assert_eq "impl_repair_attempts inc -> 2" "2" "$(fx_state "$RK" counter impl_repair_attempts inc)"
assert_fail_code "impl_repair_attempts capped at 2" WORKFLOW_REPAIR_LIMIT_EXCEEDED fx_state "$RK" counter impl_repair_attempts inc
assert_eq "impl_repair_attempts stayed at 2 after refused inc" "2" "$(fx_state "$RK" counter impl_repair_attempts get)"

assert_eq "review_correction_rounds inc -> 1" "1" "$(fx_state "$RK" counter review_correction_rounds inc)"
assert_eq "review_correction_rounds inc -> 2" "2" "$(fx_state "$RK" counter review_correction_rounds inc)"
assert_fail_code "review_correction_rounds capped at 2" WORKFLOW_REVIEW_CORRECTION_LIMIT_EXCEEDED fx_state "$RK" counter review_correction_rounds inc

for i in 1 2 3 4 5; do fx_state "$RK" counter review_attempts inc >/dev/null; done
assert_eq "review_attempts is monotonic with no ceiling" "5" "$(fx_state "$RK" counter review_attempts get)"
for i in 1 2 3; do fx_state "$RK" counter verification_attempts inc >/dev/null; done
assert_eq "verification_attempts is monotonic" "3" "$(fx_state "$RK" counter verification_attempts get)"

# evidence-only reassessment does not touch review_correction_rounds
RE="$(fx_repo_new)"; fx_state_init "$RE"; fx_state_to "$RE" VERIFY_WORKTREE
fx_state "$RE" transition REVIEW >/dev/null
rcr_before="$(fx_state "$RE" counter review_correction_rounds get)"
fx_state "$RE" transition REASSESS_REVIEW >/dev/null
fx_state "$RE" counter review_attempts inc >/dev/null
fx_state "$RE" transition REVIEW >/dev/null
assert_eq "evidence-only reassessment leaves review_correction_rounds unchanged" \
  "$rcr_before" "$(fx_state "$RE" counter review_correction_rounds get)"

# --- blocker + resume + pr ------------------------------------------------

RBl="$(fx_repo_new)"; fx_state_init "$RBl"; fx_state_to "$RBl" IMPLEMENT
fx_state "$RBl" set-blocker ENV_DOWN "docker daemon unreachable" >/dev/null
assert_eq "set-blocker records code"    "ENV_DOWN" "$(fx_state "$RBl" get blocker_code)"
assert_eq "set-blocker does not change phase" "IMPLEMENT" "$(fx_state "$RBl" get phase)"
fx_state "$RBl" clear-blocker >/dev/null
assert_eq "clear-blocker clears code" "" "$(fx_state "$RBl" get blocker_code)"

fx_state "$RBl" transition HUMAN_DECISION_REQUIRED >/dev/null
assert_eq "off-ramp records resume_phase" "IMPLEMENT" "$(fx_state "$RBl" get resume_phase)"
assert_fail_code "off-ramp may not jump forward" WORKFLOW_STATE_ILLEGAL_TRANSITION fx_state "$RBl" transition VERIFY_WORKTREE
assert_ok "off-ramp may resume its paused phase" fx_state "$RBl" transition IMPLEMENT
assert_eq "resume clears resume_phase" "" "$(fx_state "$RBl" get resume_phase)"

RP="$(fx_repo_new)"; fx_state_init "$RP"; fx_state_to "$RP" IMPLEMENT
assert_fail_code "set-pr refused outside CREATE_PR" WORKFLOW_STATE_ILLEGAL_TRANSITION fx_state "$RP" set-pr --number 7 --url u
fx_state_to "$RP" CREATE_PR
assert_ok "set-pr allowed in CREATE_PR" fx_state "$RP" set-pr --number 7 --url "https://example.invalid/pr/7"
assert_eq "pr number recorded" "7" "$(fx_state "$RP" get pr_number)"

# --- atomic write: failed write preserves prior state ------------------

RA="$(fx_repo_new)"; fx_state_init "$RA"; SFA="$(fx_state_file "$RA")"
good="$(cat "$SFA")"
# make jq (used by update_state) unavailable for one call by shadowing PATH
badbin="$(mktemp -d "$TEST_TMP_ROOT/badbin.XXXXXX")"
printf '#!/bin/sh\nexit 3\n' > "$badbin/jq"; chmod +x "$badbin/jq"
set +e
( export PATH="$badbin:$PATH"; bash "$STATE_SH" --repo-root "$RA" transition VALIDATE_ISSUE ) >/dev/null 2>&1
set -e
assert_eq "failed atomic update preserved prior state" "$good" "$(cat "$SFA")"
assert_file_absent "no stray .state.json tmp left behind" "$(dirname "$SFA")/.state.json"
ls "$(dirname "$SFA")"/.state.json.* >/dev/null 2>&1 && _fail "atomic write" "stray tmp present" || _pass "no stray .state.json.* tmp"

# --- linked worktree isolation ---------------------------------------

RW="$(fx_repo_new)"; fx_state_init "$RW" "run-primary"
WT="$(fx_worktree "$RW" iso15)"
[ -f "$WT/.git" ] && _pass "linked worktree .git is a file" || _fail "worktree" ".git is not a file"
fx_state_init "$WT" "run-worktree"
wt_state="$(git -C "$WT" rev-parse --absolute-git-dir)/claude-omnivise/state.json"
assert_file_exists "worktree state lives under its own git metadata dir" "$wt_state"
assert_contains "worktree state path is under .git/worktrees/" "$wt_state" "/worktrees/"
assert_eq "worktree state carries its own run id" "run-worktree" "$(fx_state "$WT" get run_id)"
assert_eq "primary checkout state is untouched"  "run-primary"   "$(fx_state "$RW" get run_id)"
git -C "$RW" worktree remove --force "$WT" >/dev/null 2>&1 || true
