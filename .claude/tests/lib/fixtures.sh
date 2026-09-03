#!/usr/bin/env bash
#
# fixtures.sh — domain fixtures for the workflow-core test suite: 9-section
# issue-contract bodies, throwaway Git repositories, linked worktrees, and fake
# build executables. Sourced by run.sh.

# --------------------------------------------------------------------------
# Issue-contract bodies
# --------------------------------------------------------------------------
#
# fx_contract VARIANT [HEADING_PREFIX] — write a synthetic issue body to a temp
# file and print its path. The default variant is a fully valid contract whose
# own path grammar and conflict rules pass.

fx_contract() {
  local variant="${1:-valid}" hp="${2:-##}"
  local f; f="$(mktemp "$TEST_TMP_ROOT/contract.XXXXXX.md")"

  local s_problem='The current workflow behaviour is only described in prose.'
  local s_goal='Provide a small deterministic core.'
  local s_scope='Create scripts under .claude/scripts.'
  local s_oos='No orchestration is wired up.'
  local s_ac='- [ ] The core scripts exist.
- [ ] The tests pass.'
  local s_verify='- Run `bash .claude/tests/run.sh`.'
  local s_dod='- [ ] All acceptance criteria are satisfied.
- [ ] Review reports no blocking findings.'
  local s_gates='None.'
  local allowed_marker="${hp}# Allowed Changed Paths"
  local protected_marker="${hp}# Protected Paths"
  local allowed_list='- `.claude/scripts/**`
- `.claude/tests/**`'
  local protected_list='- `.github/**`
- `backend/**`
- `README.md`'
  local tn_prefix='This issue is implemented manually.'
  local tn_suffix='Do not modify files outside Allowed Changed Paths.'
  local order="problem goal scope oos ac verify dod gates tn"

  case "$variant" in
    valid|deep-headings) : ;;
    label-marker)
      allowed_marker='Allowed Changed Paths:'
      protected_marker='Protected Paths:'
      ;;
    contract-scope)
      # exact shape used by the verify.sh --contract-file integration tests
      allowed_marker='Allowed Changed Paths:'
      protected_marker='Protected Paths:'
      allowed_list='- .claude/scripts/**
- .claude/tests/**'
      protected_list='- backend/**
- frontend/**'
      ;;
    missing-goal)   order="problem scope oos ac verify dod gates tn" ;;
    duplicate-goal) order="problem goal goal scope oos ac verify dod gates tn" ;;
    out-of-order)   order="problem scope goal oos ac verify dod gates tn" ;;
    empty-goal)     s_goal='' ;;
    comment-goal)   s_goal='<!-- nothing to say here -->' ;;
    ac-no-checkbox) s_ac='- The core scripts exist.
- The tests pass.' ;;
    dod-no-checkbox) s_dod='- All acceptance criteria are satisfied.' ;;
    gates-none)     s_gates='None.' ;;
    gates-none-prose)
      s_gates='None.

The relevant architecture decisions are already resolved and need no gate.' ;;
    gates-none-unchecked)
      s_gates='None.

- [ ] Maintainer must confirm the compatibility break.' ;;
    gates-none-checked)
      s_gates='None.

- [x] Confirmed the historical value was a dummy.' ;;
    gates-none-pending)
      s_gates='None.

- PENDING: waiting on the maintainer to decide.' ;;
    gates-none-unresolved-marker)
      s_gates='None.

- UNRESOLVED: needs a human.' ;;
    gates-resolved) s_gates='- [x] Confirmed the historical value was a dummy.' ;;
    gates-unresolved) s_gates='- [ ] Maintainer must confirm the compatibility break.' ;;
    gates-malformed) s_gates='Someone should probably look into whether this matters.' ;;
    verify-fenced-only)
      s_verify='```text
bash .claude/tests/run.sh
```' ;;
    verify-empty-fence)
      s_verify='```text
```' ;;
    verify-fenced-heading-only)
      s_verify='```text
'"${hp}"' Goal
some deterministic evidence line
```' ;;
    tn-none)        tn_prefix='None'; tn_suffix=''; allowed_marker=''; protected_marker=''
                    allowed_list=''; protected_list='' ;;
    path-absolute)  allowed_list='- `/etc/passwd`' ;;
    path-dotdot)    allowed_list='- `../other/src/**`' ;;
    path-tilde)     allowed_list='- `~/secrets`' ;;
    path-wildcard)  allowed_list='- `.claude/scripts/*.sh`' ;;
    path-metachar)  allowed_list='- `.claude/scripts/$FOO`' ;;
    conflict-literal)
      allowed_list='- `README.md`
- `.claude/scripts/**`'
      ;;
    conflict-literal-prefix)
      allowed_list='- `backend/pom.xml`
- `.claude/scripts/**`'
      ;;
    conflict-prefix-literal)
      protected_list='- `.claude/scripts/verify.sh`
- `README.md`'
      ;;
    conflict-prefix-prefix)
      protected_list='- `.claude/scripts/**`
- `README.md`'
      ;;
    disjoint) : ;;
    fenced-backtick-heading)
      s_problem='The current workflow behaviour is only described in prose.

```text
'"${hp}"' Goal
this fenced heading must be ignored
```'
      ;;
    fenced-tilde-heading)
      s_problem='The current workflow behaviour is only described in prose.

~~~text
'"${hp}"' Goal
this fenced heading must be ignored
~~~'
      ;;
    *) printf 'fx_contract: unknown variant: %s\n' "$variant" >&2; return 1 ;;
  esac

  : >"$f"
  local part
  for part in $order; do
    case "$part" in
      problem) printf '%s Problem / Context\n\n%s\n\n' "$hp" "$s_problem" >>"$f" ;;
      goal)    printf '%s Goal\n\n%s\n\n' "$hp" "$s_goal" >>"$f" ;;
      scope)   printf '%s Scope\n\n%s\n\n' "$hp" "$s_scope" >>"$f" ;;
      oos)     printf '%s Out of Scope\n\n%s\n\n' "$hp" "$s_oos" >>"$f" ;;
      ac)      printf '%s Acceptance Criteria\n\n%s\n\n' "$hp" "$s_ac" >>"$f" ;;
      verify)  printf '%s Verification\n\n%s\n\n' "$hp" "$s_verify" >>"$f" ;;
      dod)     printf '%s Definition of Done\n\n%s\n\n' "$hp" "$s_dod" >>"$f" ;;
      gates)   printf '%s Human Gates / Maintainer Decisions\n\n%s\n\n' "$hp" "$s_gates" >>"$f" ;;
      tn)
        {
          printf '%s Technical Notes / Constraints\n\n%s\n\n' "$hp" "$tn_prefix"
          if [ -n "$allowed_marker" ]; then
            printf '%s\n\n%s\n\n' "$allowed_marker" "$allowed_list"
            printf '%s\n\n%s\n\n' "$protected_marker" "$protected_list"
          fi
          [ -n "$tn_suffix" ] && printf '%s\n' "$tn_suffix"
        } >>"$f"
        ;;
    esac
  done

  printf '%s' "$f"
}

# --------------------------------------------------------------------------
# Throwaway Git repositories
# --------------------------------------------------------------------------

# fx_repo_new — create an empty committed Git repo, print its absolute path.
fx_repo_new() {
  local repo; repo="$(mktemp -d "$TEST_TMP_ROOT/repo.XXXXXX")"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name fixture
  git -C "$repo" config commit.gpgsign false
  printf 'baseline\n' >"$repo/.keep"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit -qm baseline >/dev/null
  printf '%s' "$repo"
}

# fx_git REPO ARGS... — run git in REPO.
fx_git() { local r="$1"; shift; git -C "$r" "$@"; }

# fx_commit REPO MSG — stage everything and commit.
fx_commit() {
  local r="$1" m="$2"
  git -C "$r" add -A >/dev/null
  git -C "$r" commit -qm "$m" >/dev/null
}

# fx_worktree REPO NAME — add a linked worktree on a new branch, print its path.
fx_worktree() {
  local r="$1" name="$2" wt
  wt="$(mktemp -d "$TEST_TMP_ROOT/wt.XXXXXX")"
  rmdir "$wt"
  git -C "$r" worktree add -q -b "wt/$name" "$wt" >/dev/null 2>&1
  printf '%s' "$wt"
}

# --------------------------------------------------------------------------
# workflow-state helpers
# --------------------------------------------------------------------------

# fx_state REPO ARGS... — run workflow-state.sh against REPO.
fx_state() { local r="$1"; shift; bash "$STATE_SH" --repo-root "$r" "$@"; }

# fx_state_init REPO [RUNID] — create a valid FETCH_ISSUE state.
fx_state_init() {
  local r="$1" run_id="${2:-run-fixture-1}" bc
  bc="$(git -C "$r" rev-parse HEAD)"
  fx_state "$r" init \
    --run-id "$run_id" \
    --issue-number 15 \
    --issue-title "fixture issue" \
    --issue-url "https://example.invalid/issues/15" \
    --feature-branch "feat/15-fixture" \
    --base-branch main \
    --base-commit "$bc" \
    --contract-hash "deadbeef" \
    --allowed-path ".claude/scripts/**" \
    --allowed-path ".claude/tests/**" \
    --protected-path "backend/**" \
    --protected-path "README.md" >/dev/null
}

# fx_state_file REPO — print the state file path for REPO's current worktree.
fx_state_file() {
  printf '%s/claude-omnivise/state.json' "$(git -C "$1" rev-parse --absolute-git-dir)"
}

# fx_state_to REPO TARGET — walk the happy path from the current phase to TARGET.
fx_state_to() {
  local r="$1" target="$2" cur step
  local path="FETCH_ISSUE VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW \
RESOLVE_HUMAN_GATES STAGE VERIFY_STAGED COMMIT PUSH CREATE_PR PR_READY_FOR_HUMAN_REVIEW"
  cur="$(fx_state "$r" get phase)"
  local seen=0
  for step in $path; do
    if [ "$seen" -eq 0 ]; then [ "$step" = "$cur" ] && seen=1; continue; fi
    fx_state "$r" transition "$step" >/dev/null
    [ "$step" = "$target" ] && return 0
  done
}

# fx_state_reach REPO PHASE — drive a freshly initialised state (FETCH_ISSUE) to
# PHASE using only legal transitions, taking branch detours where needed. Used by
# the transition-matrix test to land on any "from" phase.
fx_state_reach() {
  local r="$1" phase="$2" s
  local seq
  case "$phase" in
    FETCH_ISSUE)            seq="" ;;
    VALIDATE_ISSUE)         seq="VALIDATE_ISSUE" ;;
    PLAN)                   seq="VALIDATE_ISSUE PLAN" ;;
    IMPLEMENT)              seq="VALIDATE_ISSUE PLAN IMPLEMENT" ;;
    VERIFY_WORKTREE)        seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE" ;;
    REPAIR_IMPLEMENTATION)  seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REPAIR_IMPLEMENTATION" ;;
    REVIEW)                 seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW" ;;
    REASSESS_REVIEW)        seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW REASSESS_REVIEW" ;;
    FIX)                    seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW FIX" ;;
    RESOLVE_HUMAN_GATES)    seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES" ;;
    STAGE)                  seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES STAGE" ;;
    VERIFY_STAGED)          seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES STAGE VERIFY_STAGED" ;;
    COMMIT)                 seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES STAGE VERIFY_STAGED COMMIT" ;;
    PUSH)                   seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES STAGE VERIFY_STAGED COMMIT PUSH" ;;
    CREATE_PR)              seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES STAGE VERIFY_STAGED COMMIT PUSH CREATE_PR" ;;
    PR_READY_FOR_HUMAN_REVIEW) seq="VALIDATE_ISSUE PLAN IMPLEMENT VERIFY_WORKTREE REVIEW RESOLVE_HUMAN_GATES STAGE VERIFY_STAGED COMMIT PUSH CREATE_PR PR_READY_FOR_HUMAN_REVIEW" ;;
    *) printf 'fx_state_reach: cannot reach %s\n' "$phase" >&2; return 1 ;;
  esac
  for s in $seq; do fx_state "$r" transition "$s" >/dev/null; done
}

# --------------------------------------------------------------------------
# Fake build executables
# --------------------------------------------------------------------------
#
# fx_fakebin_dir — create a directory to prepend to PATH.
# fx_fake_cmd DIR NAME EXIT_CODE [BODY] — write an executable NAME that prints
# BODY (to stdout) and exits EXIT_CODE. BODY may reference $INVOCATION_LOG.

fx_fakebin_dir() {
  local d; d="$(mktemp -d "$TEST_TMP_ROOT/fakebin.XXXXXX")"
  printf '%s' "$d"
}

fx_fake_cmd() {
  local dir="$1" name="$2" code="$3" body="${4:-}"
  local p="$dir/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '[ -n "${INVOCATION_LOG:-}" ] && printf "%%s\\n" "%s $*" >>"$INVOCATION_LOG" 2>/dev/null || true\n' "$name"
    [ -n "$body" ] && printf '%s\n' "$body"
    printf 'exit %s\n' "$code"
  } >"$p"
  chmod +x "$p"
}
