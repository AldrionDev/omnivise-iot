#!/usr/bin/env bash
# launcher_test.sh — Issue #19 external launcher / bootstrap boundary.
#
# Every case runs against a disposable clone of a local bare "origin" under
# $TEST_TMP_ROOT. No real remote is contacted, no GitHub call is made, and the
# maintainer's repository is never touched.

# shellcheck source=lib/orchestrator_fixtures.sh
. "$TESTS_DIR/lib/orchestrator_fixtures.sh"

suite "launcher"

L_ORIGIN="$(fxo_origin)"
L_PRIMARY="$(fxo_primary "$L_ORIGIN")"
L_CONTRACT="$(fxo_contract)"

# ========================================================================
# 1. Preconditions
# ========================================================================

assert_fail_code "launcher: missing issue number is rejected" LAUNCH_ISSUE_NUMBER_REQUIRED \
  fxo_launch --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch
assert_fail_code "launcher: non-numeric issue number is rejected" LAUNCH_ISSUE_NUMBER_REQUIRED \
  fxo_launch --issue nineteen --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch
assert_fail_code "launcher: zero issue number is rejected" LAUNCH_ISSUE_NUMBER_REQUIRED \
  fxo_launch --issue 0 --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch
assert_fail_code "launcher: missing title is rejected" LAUNCH_USAGE \
  fxo_launch --issue 31 --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch
assert_fail_code "launcher: missing contract file is rejected" LAUNCH_USAGE \
  fxo_launch --issue 31 --title "Add a thing" --repo-root "$L_PRIMARY" --no-launch --no-fetch
assert_fail_code "launcher: unknown argument is rejected" LAUNCH_USAGE \
  fxo_launch --issue 31 --title t --contract-file "$L_CONTRACT" --exec-me x \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch

# --- dirty base
L_DIRTY="$(fxo_primary "$L_ORIGIN")"
printf 'uncommitted\n' >"$L_DIRTY/dirty.txt"
assert_fail_code "launcher: dirty base checkout is rejected" LAUNCH_BASE_DIRTY \
  fxo_launch --issue 31 --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_DIRTY" --no-launch --no-fetch
assert_file_absent "launcher: dirty base created no worktree parent" \
  "$(dirname "$L_DIRTY")/omnivise-iot-worktrees"

# --- invalid base (wrong branch / not a repo)
L_WRONG="$(fxo_primary "$L_ORIGIN")"
git -C "$L_WRONG" checkout -q -b side
assert_fail_code "launcher: base checkout on the wrong branch is rejected" LAUNCH_BASE_INVALID \
  fxo_launch --issue 31 --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_WRONG" --no-launch --no-fetch
L_NOTREPO="$(mktemp -d "$TEST_TMP_ROOT/notrepo.XXXXXX")"
assert_fail_code "launcher: a non-repository base is rejected" LAUNCH_BASE_INVALID \
  fxo_launch --issue 31 --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_NOTREPO" --no-launch --no-fetch

# --- invalid contract
L_BADCONTRACT="$(fx_contract missing-goal)"
assert_fail_code "launcher: an invalid issue contract is rejected" LAUNCH_CONTRACT_INVALID \
  fxo_launch --issue 31 --title "Add a thing" --contract-file "$L_BADCONTRACT" \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch
assert_fail_code "launcher: a missing contract file is rejected" LAUNCH_CONTRACT_INVALID \
  fxo_launch --issue 31 --title "Add a thing" --contract-file "$TEST_TMP_ROOT/nope.md" \
    --repo-root "$L_PRIMARY" --no-launch --no-fetch

# --- missing origin base ref
L_NOREMOTE="$(mktemp -d "$TEST_TMP_ROOT/noremote.XXXXXX")/r"
git init -q -b main "$L_NOREMOTE"
git -C "$L_NOREMOTE" config user.email fixture@example.invalid
git -C "$L_NOREMOTE" config user.name fixture
git -C "$L_NOREMOTE" config commit.gpgsign false
printf 'x\n' >"$L_NOREMOTE/a"
git -C "$L_NOREMOTE" add -A >/dev/null && git -C "$L_NOREMOTE" commit -qm seed >/dev/null
assert_fail_code "launcher: missing origin/main is rejected" LAUNCH_BASE_REF_MISSING \
  fxo_launch --issue 31 --title "Add a thing" --contract-file "$L_CONTRACT" \
    --repo-root "$L_NOREMOTE" --no-launch --no-fetch

# ========================================================================
# 2. Deterministic identity
# ========================================================================

L_WTROOT="$(fxo_wt_root)"
run_capture fxo_launch --issue 19 --title "Add orchestrate-issue workflow and Git lifecycle" \
  --contract-file "$L_CONTRACT" --repo-root "$L_PRIMARY" --worktree-root "$L_WTROOT" \
  --issue-url "https://example.invalid/issues/19" --no-launch --no-fetch
assert_eq "launcher: bootstrap succeeds" "0" "$RC"
assert_json "launcher: bootstrap summary is JSON" "$OUT"
L_SUMMARY="$OUT"
L_WT="$(printf '%s' "$L_SUMMARY" | jq -r '.worktree')"
L_BRANCH="$(printf '%s' "$L_SUMMARY" | jq -r '.branch')"
L_RUNID="$(printf '%s' "$L_SUMMARY" | jq -r '.run_id')"

assert_eq "launcher: branch name is <type>/<issue>-<slug>" \
  "feat/19-add-orchestrate-issue-workflow-and-git" "$L_BRANCH"
assert_eq "launcher: worktree is named by the issue number" "19" "$(basename "$L_WT")"
assert_file_exists "launcher: the worktree exists" "$L_WT"
assert_eq "launcher: the worktree is checked out on the issue branch" \
  "$L_BRANCH" "$(git -C "$L_WT" rev-parse --abbrev-ref HEAD)"
assert_eq "launcher: the worktree starts from the intended origin/main commit" \
  "$(git -C "$L_PRIMARY" rev-parse refs/remotes/origin/main)" "$(git -C "$L_WT" rev-parse HEAD)"
assert_eq "launcher: the recorded base commit is origin/main" \
  "$(git -C "$L_PRIMARY" rev-parse refs/remotes/origin/main)" \
  "$(printf '%s' "$L_SUMMARY" | jq -r '.base_commit')"

# --- deterministic default worktree location (no --worktree-root)
assert_eq "launcher: default worktree path is ../omnivise-iot-worktrees/<issue>" \
  "$(dirname "$L_PRIMARY")/omnivise-iot-worktrees/77" \
  "$(bash -c '. "$0"/lib/orchestrator-common.sh >/dev/null 2>&1; orch_worktree_path "$1" 77' \
     "$SCRIPTS_DIR" "$L_PRIMARY")"

# --- type/slug derivation is a closed, deterministic mapping
derive() {
  bash -c '. "$0"/lib/orchestrator-common.sh >/dev/null 2>&1; printf "%s/%s" "$(orch_derive_type "$1")" "$(orch_derive_slug "$1")"' \
    "$SCRIPTS_DIR" "$1"
}
assert_eq "derive: feat by default"      "feat/add-a-live-sensor-panel"      "$(derive 'Add a live sensor panel')"
assert_eq "derive: fix from title"       "fix/websocket-reconnect-loop"      "$(derive 'Fix websocket reconnect loop')"
assert_eq "derive: refactor from title"  "refactor/mongo-uri-handling"       "$(derive 'Refactor Mongo URI handling')"
assert_eq "derive: docs from title"      "docs/update-the-runbook"           "$(derive 'Docs update the runbook')"
assert_eq "derive: chore from title"     "chore/pin-the-toolchain"           "$(derive 'Chore pin the toolchain')"
assert_eq "derive: punctuation collapses" "feat/k8s-mongodb-replica-set"     "$(derive 'K8s: MongoDB   replica-set!!')"
assert_eq "derive: same title, same result" "$(derive 'Add a live sensor panel')" "$(derive 'Add a live sensor panel')"

# ========================================================================
# 3. Run identity and worktree-local state
# ========================================================================

assert_ok "launcher: the run id is a UUID" \
  bash -c '. "$0"/lib/orchestrator-common.sh >/dev/null 2>&1; orch_is_uuid "$1"' "$SCRIPTS_DIR" "$L_RUNID"
assert_eq "launcher: the run id reached workflow state" \
  "$L_RUNID" "$(fxo_state "$L_WT" get run_id)"
assert_ne "launcher: a second bootstrap generates a different run id" \
  "$L_RUNID" "$(bash -c '. "$0"/lib/orchestrator-common.sh >/dev/null 2>&1; orch_new_run_id' "$SCRIPTS_DIR")"

assert_ok "launcher: worktree-local workflow state validates" fxo_state "$L_WT" validate
assert_eq "launcher: the first persisted phase is FETCH_ISSUE" "FETCH_ISSUE" "$(fxo_phase "$L_WT")"
assert_eq "launcher: the issue number is recorded" "19" "$(fxo_state "$L_WT" get issue_number)"
assert_eq "launcher: the feature branch is recorded" "$L_BRANCH" "$(fxo_state "$L_WT" get feature_branch)"
assert_eq "launcher: the base branch is recorded" "main" "$(fxo_state "$L_WT" get base_branch)"
assert_eq "launcher: the contract hash is recorded" \
  "$(bash "$CONTRACT_SH" hash "$L_CONTRACT")" "$(fxo_state "$L_WT" get contract_hash)"
assert_eq "launcher: counters start at zero" "0000" \
  "$(fxo_state "$L_WT" get impl_repair_attempts)$(fxo_state "$L_WT" get review_attempts)$(fxo_state "$L_WT" get review_correction_rounds)$(fxo_state "$L_WT" get verification_attempts)"

# --- the contract is stored as evidence outside the candidate
L_SD="$(fxo_state_dir "$L_WT")"
assert_file_exists "launcher: the contract is stored as workflow evidence" "$L_SD/issue-contract.md"
assert_eq "launcher: the worktree candidate is empty after bootstrap" \
  "[]" "$(bash "$CANDIDATE_SH" --repo-root "$L_WT" list)"
assert_eq "launcher: the index is empty after bootstrap" \
  "" "$(git -C "$L_WT" diff --cached --name-only)"

# --- worktree creation is a bootstrap step, never a persisted phase
assert_not_contains "launcher: no worktree-creation phase is persisted in state" \
  "$(cat "$L_SD/state.json")" "CREATE_WORKTREE"
for f in launch-issue.sh orchestrator.sh lifecycle.sh lib/orchestrator-common.sh; do
  assert_not_contains "no worktree-creation phase token in $f" \
    "$(cat "$SCRIPTS_DIR/$f")" "CREATE_WORKTREE"
done
assert_not_contains "state machine declares no worktree-creation phase" \
  "$(cat "$STATE_SH")" "CREATE_WORKTREE"

# ========================================================================
# 4. Collisions fail safely
# ========================================================================

assert_fail_code "launcher: duplicate branch collision fails safely" LAUNCH_BRANCH_EXISTS \
  fxo_launch --issue 19 --title "Add orchestrate-issue workflow and Git lifecycle" \
    --contract-file "$L_CONTRACT" --repo-root "$L_PRIMARY" \
    --worktree-root "$(fxo_wt_root)" --no-launch --no-fetch

L_WTROOT2="$(fxo_wt_root)"
mkdir -p "$L_WTROOT2/21"
assert_fail_code "launcher: existing worktree path collision fails safely" LAUNCH_WORKTREE_EXISTS \
  fxo_launch --issue 21 --title "Something else entirely" --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --worktree-root "$L_WTROOT2" --no-launch --no-fetch
assert_ok "launcher: the colliding branch was NOT created" \
  bash -c '! git -C "$1" show-ref --verify --quiet refs/heads/feat/21-something-else-entirely' _ "$L_PRIMARY"

# a collision leaves the previously created run untouched
assert_eq "launcher: collision left the existing worktree state intact" \
  "FETCH_ISSUE" "$(fxo_phase "$L_WT")"

# ========================================================================
# 5. Failure never continues into implementation
# ========================================================================

: >"$FXO_CTL/claude.log"
assert_fail "launcher: a failing bootstrap exits non-zero" \
  fxo_launch --issue 0 --title t --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --worktree-root "$(fxo_wt_root)" --no-fetch
assert_eq "launcher: a failing bootstrap never launched Claude" "" "$(cat "$FXO_CTL/claude.log")"

# state-init failure rolls the branch and worktree back
L_ROLL_PRIMARY="$(fxo_primary "$L_ORIGIN")"
L_ROLL_WTROOT="$(fxo_wt_root)"
L_BROKEN_STATE="$(mktemp -d "$TEST_TMP_ROOT/brokenstate.XXXXXX")/workflow-state.sh"
printf '#!/usr/bin/env bash\nprintf "WORKFLOW_STATE_INVALID: injected\\n" >&2\nexit 1\n' >"$L_BROKEN_STATE"
roll_launch() {
  env "ORCH_STATE_SH=$L_BROKEN_STATE" "PATH=$FXO_BIN:$PATH" bash "$LAUNCH_SH" \
    --issue 44 --title "Rollback probe" --contract-file "$L_CONTRACT" \
    --repo-root "$L_ROLL_PRIMARY" --worktree-root "$L_ROLL_WTROOT" --no-launch --no-fetch
}
assert_fail_code "launcher: workflow-state init failure is fatal" LAUNCH_STATE_INIT_FAILED roll_launch
assert_file_absent "launcher: rollback removed the worktree" "$L_ROLL_WTROOT/44"
assert_ok "launcher: rollback removed the branch" \
  bash -c '! git -C "$1" show-ref --verify --quiet refs/heads/feat/44-rollback-probe' _ "$L_ROLL_PRIMARY"

# ========================================================================
# 6. Launch handoff
# ========================================================================

L_LAUNCH_WTROOT="$(fxo_wt_root)"
: >"$FXO_CTL/claude.log"
run_capture fxo_launch --issue 55 --title "Launch handoff probe" --contract-file "$L_CONTRACT" \
  --repo-root "$L_PRIMARY" --worktree-root "$L_LAUNCH_WTROOT" --no-fetch --claude-bin claude
assert_eq "launcher: launching bootstrap succeeds" "0" "$RC"
L_LOG="$(cat "$FXO_CTL/claude.log")"
assert_contains "launcher: Claude is started in orchestrator mode" "$L_LOG" "orchestrator|"
assert_contains "launcher: the generated run id is exported to the child" \
  "$L_LOG" "$(fxo_state "$L_LAUNCH_WTROOT/55" get run_id)"
assert_contains "launcher: Claude is started inside the issue worktree" \
  "$L_LOG" "$L_LAUNCH_WTROOT/55"

L_NOCLI_WTROOT="$(fxo_wt_root)"
assert_fail_code "launcher: a missing Claude CLI is fatal" LAUNCH_CLAUDE_MISSING \
  fxo_launch --issue 56 --title "No CLI probe" --contract-file "$L_CONTRACT" \
    --repo-root "$L_PRIMARY" --worktree-root "$L_NOCLI_WTROOT" --no-fetch \
    --claude-bin no-such-claude-binary-xyz
assert_file_absent "launcher: a missing Claude CLI created no worktree" "$L_NOCLI_WTROOT/56"
assert_ok "launcher: a missing Claude CLI created no branch" \
  bash -c '! git -C "$1" show-ref --verify --quiet refs/heads/feat/56-no-cli-probe' _ "$L_PRIMARY"

# ========================================================================
# 7. Real-repository isolation
# ========================================================================

assert_eq "launcher isolation: real repo status unchanged" \
  "" "$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"
