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
# 7. Isolation
# ========================================================================

assert_eq "lifecycle isolation: real repo index unchanged" \
  "" "$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"
assert_eq "lifecycle isolation: real repo branch unchanged" \
  "$LC_REAL_BRANCH_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" rev-parse --abbrev-ref HEAD)"
assert_eq "lifecycle isolation: real repo HEAD unchanged" \
  "$LC_REAL_HEAD_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" rev-parse HEAD)"
