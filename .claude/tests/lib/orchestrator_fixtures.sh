#!/usr/bin/env bash
#
# orchestrator_fixtures.sh — helpers for the Issue #19 orchestration suites
# (launcher_test.sh, orchestrator_test.sh, lifecycle_test.sh).
#
# Everything is offline and disposable:
#   * "origin" is a local bare repository under $TEST_TMP_ROOT, never a remote
#     host, so a push is real Git but touches nothing outside the temp root;
#   * `gh` is a stub on PATH — no pull request is ever created;
#   * verify.sh is substituted with a deterministic stub through ORCH_VERIFY_SH,
#     so no Maven / npm / Docker command ever runs.
#
# The real repository is never mutated. Helpers use an fxo_ prefix so they cannot
# collide with lib/fixtures.sh or lib/safety_fixtures.sh.
#
# $SCRIPTS_DIR / $TEST_TMP_ROOT / $CANDIDATE_SH come from run.sh.

ORCH_SH="$SCRIPTS_DIR/orchestrator.sh"
LAUNCH_SH="$SCRIPTS_DIR/launch-issue.sh"
LIFECYCLE_SH="$SCRIPTS_DIR/lifecycle.sh"

# --------------------------------------------------------------------------
# Stub executables and the verify substitute
# --------------------------------------------------------------------------

FXO_BIN="$(mktemp -d "$TEST_TMP_ROOT/orch-bin.XXXXXX")"
FXO_CTL="$(mktemp -d "$TEST_TMP_ROOT/orch-ctl.XXXXXX")"
FXO_VERIFY_STUB="$FXO_CTL/verify-stub.sh"
FXO_GH_LOG="$FXO_CTL/gh.log"

printf 'PASS\n' >"$FXO_CTL/verify-result"

# fxo_set_verify RESULT — PASS | FAIL_IMPLEMENTATION | FAIL_ENVIRONMENT |
# TOOL_UNAVAILABLE | FAIL_WORKTREE_MUTATION | INDETERMINATE
fxo_set_verify() { printf '%s\n' "$1" >"$FXO_CTL/verify-result"; }

cat >"$FXO_VERIFY_STUB" <<'STUB'
#!/usr/bin/env bash
# Deterministic stand-in for verify.sh. It performs no build, but it does compute
# the REAL candidate fingerprint so the orchestrator's freshness checks are
# exercised for real.
set -uo pipefail
mode=worktree; repo="$PWD"; record=""; reviewed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --repo-root) repo="$2"; shift 2 ;;
    --record) record="$2"; shift 2 ;;
    --reviewed-manifest) reviewed="$2"; shift 2 ;;
    *) shift ;;
  esac
done
result="$(cat "$FXO_CTL/verify-result" 2>/dev/null || printf 'PASS')"
# Staged mode keeps the REAL staged-vs-reviewed proof: this is the property the
# workflow depends on, so it is never stubbed away.
if [ "$mode" = staged ]; then
  ok="$(bash "$CANDIDATE_SH" --repo-root "$repo" staged-compare --reviewed-manifest "$reviewed" 2>/dev/null | jq -r '.ok // false')"
  [ "$ok" = true ] || result=FAIL_IMPLEMENTATION
fi
fp="$(bash "$CANDIDATE_SH" --repo-root "$repo" fingerprint 2>/dev/null || printf '')"
if [ "$result" = PASS ]; then
  suite=PASS; cls=PASS; rc=0
else
  suite=FAIL; cls="$result"; rc=1
fi
rec="$(jq -cn --arg mode "$mode" --arg fp "$fp" --arg suite "$suite" --arg cls "$cls" \
  '{schema_version:1, verification_mode:$mode,
    candidate:{fingerprint:$fp, enumeration_ok:true, paths:[]},
    checks:[{id:"stub", kind:"builtin", classification:$cls}],
    result:$suite, stopped_early:false, stopped_reason:null}')"
printf '%s\n' "$rec"
[ -n "$record" ] && printf '%s\n' "$rec" >"$record"
exit "$rc"
STUB
chmod +x "$FXO_VERIFY_STUB"

# `gh` stub: records its invocation and prints a deterministic PR URL.
cat >"$FXO_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "gh $*" >>"$FXO_GH_LOG" 2>/dev/null || true
case "${1:-}" in
  pr)
    case "${2:-}" in
      create) printf 'https://github.com/example/omnivise-iot/pull/4242\n'; exit 0 ;;
    esac
    ;;
esac
exit 1
GHSTUB
chmod +x "$FXO_BIN/gh"

# A `claude` stub for the launcher's exec path; it records that it was launched.
cat >"$FXO_BIN/claude" <<'CLSTUB'
#!/usr/bin/env bash
set -u
printf '%s|%s|%s\n' "${OMNIVISE_WORKFLOW_MODE:-}" "${OMNIVISE_RUN_ID:-}" "$PWD" \
  >>"$FXO_CTL/claude.log" 2>/dev/null || true
exit 0
CLSTUB
chmod +x "$FXO_BIN/claude"

# --------------------------------------------------------------------------
# Disposable repositories
# --------------------------------------------------------------------------

# fxo_origin — a bare repository seeded with one commit on main; prints its path.
fxo_origin() {
  local root origin seed
  root="$(mktemp -d "$TEST_TMP_ROOT/orch-remote.XXXXXX")"
  origin="$root/origin.git"
  seed="$root/seed"
  git init --bare -q -b main "$origin"
  git init -q -b main "$seed"
  git -C "$seed" config user.email fixture@example.invalid
  git -C "$seed" config user.name fixture
  git -C "$seed" config commit.gpgsign false
  mkdir -p "$seed/.claude/scripts" "$seed/.claude/tests" "$seed/backend"
  printf 'baseline\n' >"$seed/.keep"
  printf 'seed\n' >"$seed/backend/Main.java"
  git -C "$seed" add -A >/dev/null
  git -C "$seed" commit -qm baseline >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin main
  printf '%s' "$origin"
}

# fxo_primary ORIGIN — a clean clone on main; prints its path.
fxo_primary() {
  local origin="$1" p
  p="$(mktemp -d "$TEST_TMP_ROOT/orch-primary.XXXXXX")/primary"
  git clone -q "$origin" "$p"
  git -C "$p" config user.email fixture@example.invalid
  git -C "$p" config user.name fixture
  git -C "$p" config commit.gpgsign false
  printf '%s' "$p"
}

# fxo_contract — a valid 9-section contract whose path contract matches the
# candidates these suites create; prints its path.
fxo_contract() { fx_contract contract-scope; }

# fxo_wt_root — a disposable parent directory for a launcher worktree.
fxo_wt_root() {
  local d; d="$(mktemp -d "$TEST_TMP_ROOT/orch-wtroot.XXXXXX")"
  printf '%s' "$d"
}

# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------

# fxo_launch ARGS... — run the launcher with the stub PATH.
fxo_launch() {
  env "FXO_CTL=$FXO_CTL" "PATH=$FXO_BIN:$PATH" bash "$LAUNCH_SH" "$@"
}

# fxo_orch REPO EVENT [ARGS...] — run one orchestration event against REPO.
fxo_orch() {
  local repo="$1" event="$2"; shift 2
  env OMNIVISE_WORKFLOW_MODE=orchestrator \
      "ORCH_VERIFY_SH=$FXO_VERIFY_STUB" \
      "FXO_CTL=$FXO_CTL" "CANDIDATE_SH=$CANDIDATE_SH" \
      "FXO_GH_LOG=$FXO_GH_LOG" "PATH=$FXO_BIN:$PATH" \
      bash "$ORCH_SH" "$event" --repo-root "$repo" "$@"
}

# fxo_orch_mode MODE REPO EVENT [ARGS...] — same, with an arbitrary workflow mode.
fxo_orch_mode() {
  local mode="$1" repo="$2" event="$3"; shift 3
  local -a e=(env)
  [ "$mode" = "-unset-" ] && e+=(-u OMNIVISE_WORKFLOW_MODE)
  [ "$mode" != "-unset-" ] && e+=("OMNIVISE_WORKFLOW_MODE=$mode")
  e+=("ORCH_VERIFY_SH=$FXO_VERIFY_STUB" "FXO_CTL=$FXO_CTL" "CANDIDATE_SH=$CANDIDATE_SH"
      "FXO_GH_LOG=$FXO_GH_LOG" "PATH=$FXO_BIN:$PATH")
  "${e[@]}" bash "$ORCH_SH" "$event" --repo-root "$repo" "$@"
}

# fxo_lifecycle MODE INVOCATION REPO OP — call the lifecycle helper directly.
fxo_lifecycle() {
  local mode="$1" inv="$2" repo="$3" op="$4"
  # every `env -u` flag must precede the first NAME=VALUE assignment
  local -a e=(env)
  [ "$mode" = "-unset-" ] && e+=(-u OMNIVISE_WORKFLOW_MODE)
  [ "$inv" = "-unset-" ] && e+=(-u OMNIVISE_LIFECYCLE_INVOCATION)
  [ "$mode" != "-unset-" ] && e+=("OMNIVISE_WORKFLOW_MODE=$mode")
  [ "$inv" != "-unset-" ] && e+=("OMNIVISE_LIFECYCLE_INVOCATION=$inv")
  e+=("FXO_GH_LOG=$FXO_GH_LOG" "PATH=$FXO_BIN:$PATH")
  "${e[@]}" bash "$LIFECYCLE_SH" --repo-root "$repo" "$op"
}

# fxo_state REPO ARGS... — read/drive workflow state directly (test scaffolding).
fxo_state() { local r="$1"; shift; bash "$STATE_SH" --repo-root "$r" "$@"; }

fxo_phase() { fxo_state "$1" get phase; }

fxo_state_dir() { printf '%s/claude-omnivise' "$(git -C "$1" rev-parse --absolute-git-dir)"; }

# fxo_candidate REPO [NAME] — write an in-scope candidate file into REPO.
fxo_candidate() {
  local r="$1" name="${2:-orchestrated.sh}"
  mkdir -p "$r/.claude/scripts"
  printf '#!/usr/bin/env bash\necho %s\n' "$name" >"$r/.claude/scripts/$name"
}

# fxo_bootstrap — origin + primary + contract + a launched (but not started)
# issue worktree. Prints "<worktree>|<primary>|<origin>|<contract>".
fxo_bootstrap() {
  local issue="${1:-19}" title="${2:-Add orchestrate issue workflow}"
  local origin primary contract wtroot out wt
  origin="$(fxo_origin)"
  primary="$(fxo_primary "$origin")"
  contract="$(fxo_contract)"
  wtroot="$(fxo_wt_root)"
  out="$(fxo_launch --issue "$issue" --title "$title" --contract-file "$contract" \
        --repo-root "$primary" --worktree-root "$wtroot" --no-launch --no-fetch)"
  wt="$(printf '%s' "$out" | jq -r '.worktree')"
  printf '%s|%s|%s|%s' "$wt" "$primary" "$origin" "$contract"
}

# fxo_drive_to_review REPO — candidate + verify PASS + fresh review, leaving the
# workflow in REVIEW.
fxo_drive_to_review() {
  local r="$1"
  fxo_orch "$r" validate-contract >/dev/null
  fxo_orch "$r" begin-plan >/dev/null
  fxo_orch "$r" begin-implement >/dev/null
  fxo_candidate "$r"
  fxo_set_verify PASS
  fxo_orch "$r" verify-worktree >/dev/null
  fxo_orch "$r" begin-review >/dev/null
}
