#!/usr/bin/env bash
# safety_guard_test.sh — Issue #17 Claude workflow safety boundary.
#
# Every case invokes a guard script directly (via fx_guard / a small raw helper)
# with a crafted environment and stdin payload, then asserts:
#   deny  -> non-zero exit AND a stable SAFETY_* code on stderr
#   allow -> exit 0 with empty stdout
# All offline, all under $TEST_TMP_ROOT. The real repository lifecycle is
# captured before and after the suite and asserted unchanged.

# shellcheck source=lib/safety_fixtures.sh
. "$TESTS_DIR/lib/safety_fixtures.sh"

suite "safety-guard"

G_FW="framework-write-guard.sh"
G_SH="shell-guard.sh"
G_WC="worktree-create-guard.sh"

# gd NAME CODE MODE GUARD JSON [PDIR] — expect deny with CODE.
gd() { assert_fail_code "$1" "$2" fx_guard "$3" "$4" "$5" "${6:-$FX_PD}"; }
# ga NAME MODE GUARD JSON [PDIR] — expect allow (exit 0).
ga() { assert_ok "$1" fx_guard "$2" "$3" "$4" "${5:-$FX_PD}"; }

fwe() { fx_edit_input "$1" "${2:-Write}"; }   # framework-write payload (file_path)

# --- real-repository isolation: snapshot before ----------------------------
REPO_BRANCH_BEFORE="$(git -C "$OMNIVISE_REPO_ROOT" rev-parse --abbrev-ref HEAD)"
REPO_STATUS_BEFORE="$(git -C "$OMNIVISE_REPO_ROOT" status --porcelain)"
REPO_HEAD_BEFORE="$(git -C "$OMNIVISE_REPO_ROOT" rev-parse HEAD)"
REPO_INDEX_BEFORE="$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"

# ========================================================================
# 1. Execution mode (through both PreToolUse guards)
# ========================================================================

gd "mode: unset -> strict framework deny" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "-unset-" "$G_FW" "$(fwe '.claude/scripts/verify.sh')"
gd "mode: unset -> strict git deny" SAFETY_GIT_MUTATION_DENIED \
  "-unset-" "$G_SH" "$(fx_bash_input 'git add -A')"
gd "mode: empty -> strict (not MODE_INVALID)" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "" "$G_FW" "$(fwe '.claude/settings.json')"
gd "mode: issue -> strict framework deny" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe '.claude/hooks/shell-guard.sh')"
ga "mode: framework-maintenance -> framework write allowed" \
  "framework-maintenance" "$G_FW" "$(fwe '.claude/scripts/verify.sh')"
gd "mode: framework-maintenance -> git still denied" SAFETY_GIT_MUTATION_DENIED \
  "framework-maintenance" "$G_SH" "$(fx_bash_input 'git commit -m x')"
gd "mode: framework-maintenance -> non-allowlisted Bash still denied" SAFETY_SHELL_COMMAND_DENIED \
  "framework-maintenance" "$G_SH" "$(fx_bash_input "python3 -c x")"
gd "mode: framework-maintenance -> git-metadata write still denied" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "framework-maintenance" "$G_FW" "$(fwe '.git/config')"
for bad in frameworkmaintenance ISSUE Issue x " " maintenance; do
  gd "mode: malformed '$bad' (framework guard)" SAFETY_MODE_INVALID \
    "$bad" "$G_FW" "$(fwe 'backend/src/Main.java')"
  gd "mode: malformed '$bad' (shell guard)" SAFETY_MODE_INVALID \
    "$bad" "$G_SH" "$(fx_bash_input 'git status')"
done
gd "mode: payload-supplied mode is ignored" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "-unset-" "$G_FW" "$(fx_hook_input Edit '{"mode":"framework-maintenance","file_path":".claude/x"}')"

# ========================================================================
# 2. Framework-path writes (framework-write-guard.sh)
# ========================================================================

# --- issue mode: DENY SAFETY_FRAMEWORK_MUTATION_DENIED
for spec in \
  ".claude/scripts/verify.sh|Edit" \
  ".claude/settings.json|Write" \
  ".claude/settings.local.json|Write" \
  ".claude/hooks/shell-guard.sh|Write" \
  ".claude/hooks/guard-common.sh|Write" \
  ".claude/tests/state_test.sh|Edit" \
  ".claude/tests/lib/fixtures.sh|Edit" \
  ".claude/scripts/candidate.sh|MultiEdit" \
  "./.claude/x|Write" \
  ".claude/foo/../bar|Write"
do
  p="${spec%%|*}"; t="${spec#*|}"
  gd "framework deny (issue): $t $p" SAFETY_FRAMEWORK_MUTATION_DENIED \
    "issue" "$G_FW" "$(fwe "$p" "$t")"
done
gd "framework deny (issue): NotebookEdit .claude/analysis.ipynb" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "issue" "$G_FW" "$(fx_notebook_input '.claude/analysis.ipynb')"
gd "framework deny (issue): absolute path into .claude" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$FX_PD/.claude/scripts/x")"

# --- symlink alias resolving into .claude/  -> still denied in issue mode
PD_SYM="$(fx_pdir)"
ln -s "$PD_SYM/.claude" "$PD_SYM/alias"
ln -s "$PD_SYM/.claude/hooks" "$PD_SYM/hlink"
gd "framework deny (issue): prefix symlink alias -> .claude/settings.json" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe 'alias/settings.json')" "$PD_SYM"
gd "framework deny (issue): prefix symlink alias -> .claude/hooks/x.sh" SAFETY_FRAMEWORK_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe 'hlink/x.sh')" "$PD_SYM"

# --- issue mode: ALLOW (permitted non-framework candidate mutation)
for spec in \
  "backend/src/Main.java|Edit" \
  "frontend/src/new.tsx|Write" \
  "docs/x.md|Write" \
  "README.md|Write" \
  "backend/.claudecfg|Write" \
  "notes/claude.md|Write" \
  "src/app/service.ts|Edit"
do
  p="${spec%%|*}"; t="${spec#*|}"
  ga "non-framework write allowed (issue): $t $p" "issue" "$G_FW" "$(fwe "$p" "$t")"
done
ga "repo-other write allowed (issue): deep new nested path" \
  "issue" "$G_FW" "$(fwe 'backend/src/main/java/app/New.java')"
ga "repo-other write allowed (issue): absolute path inside the repo" \
  "issue" "$G_FW" "$(fwe "$FX_PD/backend/src/Deep.java")"

# ========================================================================
# 2a. Outside-repo writes (framework-write-guard.sh) — DENY in EVERY mode
#     with SAFETY_OUTSIDE_REPO_WRITE_DENIED. Normal Claude file tools must
#     never write outside the canonical current project root.
# ========================================================================

PD_OUT="$(fx_pdir)"
ln -s /etc "$PD_OUT/e"
ln -s /tmp "$PD_OUT/tmplink"

gd "outside-repo deny (issue): in-repo symlink resolving to /etc" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe 'e/hosts')" "$PD_OUT"
gd "outside-repo deny (issue): in-repo symlink resolving to /tmp" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe 'tmplink/x')" "$PD_OUT"
gd "outside-repo deny (issue): absolute path outside the repo" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe '/etc/cron.d/x')" "$PD_OUT"
gd "outside-repo deny (issue): \$HOME/.gitconfig-style absolute path" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe "$HOME/.gitconfig")" "$PD_OUT"
gd "outside-repo deny (issue): parent-escape via ../" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe '../escapee/x')" "$PD_OUT"
gd "outside-repo deny (issue): sibling directory of the project root" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe "$(dirname "$PD_OUT")/sibling-dir/x")" "$PD_OUT"
# path-segment-safe containment: a sibling whose name shares the root's prefix
# ("<root>-sibling") is NOT inside "<root>".
gd "outside-repo deny (issue): sibling sharing a name prefix with the root" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "issue" "$G_FW" "$(fwe "${PD_OUT}-sibling/x")" "$PD_OUT"
gd "outside-repo deny (maintenance): absolute path outside the repo still denied" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "framework-maintenance" "$G_FW" "$(fwe '/etc/cron.d/x')" "$PD_OUT"
gd "outside-repo deny (maintenance): in-repo symlink to outside still denied" SAFETY_OUTSIDE_REPO_WRITE_DENIED \
  "framework-maintenance" "$G_FW" "$(fwe 'e/hosts')" "$PD_OUT"

# normal in-repo candidate writes remain allowed even next to the escapes above
ga "repo-other write allowed (issue): ordinary file in the same project" \
  "issue" "$G_FW" "$(fwe 'backend/src/Ok.java')" "$PD_OUT"

# --- framework-maintenance: ALLOW framework writes
for p in ".claude/scripts/verify.sh" ".claude/settings.json" ".claude/agents/planner.md" ".claude/hooks/shell-guard.sh"; do
  ga "framework write allowed (maintenance): $p" "framework-maintenance" "$G_FW" "$(fwe "$p")"
done

# ========================================================================
# 2b. Git-metadata writes (framework-write-guard.sh) -> SAFETY_GIT_METADATA_MUTATION_DENIED
# ========================================================================

PD_GM="$(fx_pdir)"
for p in ".git/HEAD" ".git/config" ".git/index" ".git/refs/heads/main" ".git/hooks/pre-commit" ".git/logs/HEAD"; do
  gd "git-metadata deny (issue): $p" SAFETY_GIT_METADATA_MUTATION_DENIED \
    "issue" "$G_FW" "$(fwe "$p")" "$PD_GM"
done
gd "git-metadata deny (issue): absolute --absolute-git-dir/x" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$(git -C "$PD_GM" rev-parse --absolute-git-dir)/x")" "$PD_GM"
gd "git-metadata deny (issue): absolute --git-common-dir/config" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$(git -C "$PD_GM" rev-parse --git-common-dir)/config")" "$PD_GM"
gd "git-metadata deny (issue): the .git leaf itself" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$PD_GM/.git")" "$PD_GM"
gd "git-metadata deny (maintenance): .git/config" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "framework-maintenance" "$G_FW" "$(fwe '.git/config')" "$PD_GM"

ln -s "$PD_GM/.git" "$PD_GM/gitlink"
gd "git-metadata deny (issue): symlink resolving into .git" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe 'gitlink/config')" "$PD_GM"

for p in ".gitignore" ".gitattributes" "src/x" ".github/workflows/x.yml"; do
  ga "git-metadata: non-.git path allowed (issue): $p" "issue" "$G_FW" "$(fwe "$p")" "$PD_GM"
done

# --- linked worktree
PD_WTBASE="$(fx_pdir)"
WT="$(fx_worktree "$PD_WTBASE" a)"
gd "git-metadata deny (worktree): the .git pointer file" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$WT/.git")" "$WT"
gd "git-metadata deny (worktree): common-dir/config" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$(git -C "$WT" rev-parse --git-common-dir)/config")" "$WT"
gd "git-metadata deny (worktree): absolute-git-dir/index" SAFETY_GIT_METADATA_MUTATION_DENIED \
  "issue" "$G_FW" "$(fwe "$(git -C "$WT" rev-parse --absolute-git-dir)/index")" "$WT"
ga "git-metadata (worktree): ordinary worktree file allowed" \
  "issue" "$G_FW" "$(fwe "$WT/src/ok.txt")" "$WT"

# --- fail-closed when Git-metadata discovery cannot be trusted
GIT_SHADOW="$(mktemp -d "$TEST_TMP_ROOT/gitshadow.XXXXXX")"
printf '#!/usr/bin/env bash\nexit 1\n' >"$GIT_SHADOW/git"
chmod +x "$GIT_SHADOW/git"
FX_GUARD_PATH="$GIT_SHADOW"
gd "git broken -> .git write denied (fail-closed)" SAFETY_PATH_UNRESOLVED \
  "issue" "$G_FW" "$(fwe "$PD_GM/.git/HEAD")" "$PD_GM"
gd "git broken -> ordinary write ALSO denied (no lexical-fallback allow)" SAFETY_PATH_UNRESOLVED \
  "issue" "$G_FW" "$(fwe "$PD_GM/src/x")" "$PD_GM"
FX_GUARD_PATH=""
gd "unresolved project root -> PATH_UNRESOLVED" SAFETY_PATH_UNRESOLVED \
  "issue" "$G_FW" "$(fwe '.claude/x')" "/no/such/project/dir/xyz"

# ========================================================================
# 3. Bash — arbitrary writers & non-allowlisted commands (issue) -> SAFETY_SHELL_COMMAND_DENIED
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "shell deny: $c" SAFETY_SHELL_COMMAND_DENIED "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<'CMDS'
python3 -c open
python -c import
node -e require
perl -e open
bash -c gitcommit
bash -lc echo
sh -c :
tee .claude/x
sed -i s/a/b/ .claude/scripts/verify.sh
cp /etc/hostname .claude/x
mv .claude/a .claude/b
rm .claude/x
find .claude -type f
xargs rm
env OMNIVISE_WORKFLOW_MODE=framework-maintenance git status
export OMNIVISE_WORKFLOW_MODE=framework-maintenance
mvn -q -f backend/pom.xml package
npm --prefix frontend ci
docker compose config --quiet
docker compose up -d
cat .claude/settings.json
ls -la .claude
grep -r x .claude
curl https://example.invalid
frobnicate --now
/usr/bin/git add -A
bash /tmp/evil.sh
bash ./scripts/other.sh
CMDS
gd "shell deny: leading VAR= assignment" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'OMNIVISE_WORKFLOW_MODE=framework-maintenance git status')"
gd "shell deny: redirect >" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'git status > out.txt')"
gd "shell deny: append >>" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'git log >> out.txt')"
gd "shell deny: command substitution \$( )" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'bash .claude/scripts/verify.sh --record $(pwd)/x')"
gd "shell deny: backtick substitution" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'git log `whoami`')"
gd "shell deny: pipeline into denied writer" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'git diff | tee patch.txt')"
gd "shell deny: empty command" SAFETY_INPUT_INVALID \
  "issue" "$G_SH" "$(fx_hook_input Bash '{"command":""}')"

# ========================================================================
# 4. Git lifecycle deny (shell-guard.sh, issue) -> SAFETY_GIT_MUTATION_DENIED
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "git lifecycle deny: $c" SAFETY_GIT_MUTATION_DENIED "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<'GITS'
git add -A
git add .claude/scripts/x
git stage x
git commit -m x
git commit --amend --no-edit
git push
git push -f origin main
git switch main
git switch -c feat/x
git checkout main
git checkout -- backend/x
git reset --hard HEAD~1
git reset
git restore backend/x
git restore --staged x
git clean -fdx
git stash
git stash pop
git stash drop
git stash list
git worktree add ../wt -b b origin/main
git worktree remove ../wt
git worktree prune
git worktree list
git config user.name x
git branch feat/x
git branch --list
git tag v1
git rebase main
git merge feat/x
git cherry-pick abc
git revert abc
git rm x
git mv a b
git apply p.diff
git am p.eml
git fetch
git pull
git clone url
git frobnicate
GITS
gd "git deny: chained 2nd segment (true && git push)" SAFETY_GIT_MUTATION_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'git status && git push')"
gd "git deny: /usr/bin/git add is SHELL_COMMAND_DENIED (first token not 'git')" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input '/usr/bin/git add -A')"

# ========================================================================
# 4b. Git global options & off-grammar args (issue) -> SAFETY_GIT_MUTATION_DENIED
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "git grammar deny: $c" SAFETY_GIT_MUTATION_DENIED "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<'GRAM'
git -c core.fsmonitor=/tmp/x status
git -c core.pager=/tmp/x log
git -C /tmp/x diff
git --git-dir=/x status
git --git-dir /x status
git --work-tree=/x status
git --exec-path=/x status
git --no-pager log
git -P log
git --namespace=n status
git diff --output=.claude/x
git diff --output .claude/x
git show --output=.claude/x HEAD
git log --output=.claude/x
git diff --ext-diff
git diff --textconv
git log --exec-path=/x
git diff -O/tmp/order
git log --pretty=%x00
git log -n abc
git log --oneline --unknown
git status --porcelain=v3
git show HEAD extra
git rev-parse --sq HEAD
git diff --raw
git rev-parse --git-path hooks
git status -uall --ignored
git ls-files
git for-each-ref
git config --get user.name
git cat-file -p HEAD
git blame README.md
GRAM

# ========================================================================
# 5. GitHub CLI deny (shell-guard.sh, issue) -> SAFETY_GITHUB_MUTATION_DENIED
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "gh deny: $c" SAFETY_GITHUB_MUTATION_DENIED "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<'GHS'
gh pr create -t x -b y
gh pr merge 12 --squash
gh pr edit 12 --add-label z
gh pr close 12
gh pr review 12 --approve
gh issue create -t x -b y
gh issue edit 17 --add-label z
gh issue close 17
gh issue comment 17 -b x
gh api -X POST /repos/o/r/issues
gh api --method PATCH /repos/o/r/pulls/1
gh pr view 12
gh secret set X
GHS
gd "gh deny: chained 2nd segment" SAFETY_GITHUB_MUTATION_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'git status && gh pr create -t a -b b')"

# ========================================================================
# 6. Read-only Git & trusted scripts -> ALLOW
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  ga "read-only git allowed: $c" "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<'ROK'
git status
git status --porcelain=v2 -z
git status --porcelain -b
git diff
git diff --cached
git diff --check
git diff --stat
git diff --name-only HEAD~1..HEAD
git diff HEAD
git show HEAD
git show HEAD --stat
git show v1.2.3
git show HEAD:backend/pom.xml
git log
git log --oneline -n 20
git log --oneline --max-count=5
git log --pretty=short
git rev-parse HEAD
git rev-parse --show-toplevel
git rev-parse --absolute-git-dir
git rev-parse --git-common-dir
git rev-parse --git-dir
git rev-parse --abbrev-ref HEAD
git rev-parse --is-inside-work-tree
git rev-parse --verify HEAD
git rev-parse HEAD && git status
ROK

while IFS= read -r c; do
  [ -n "$c" ] || continue
  ga "trusted script allowed: $c" "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<SCR
bash .claude/scripts/issue-contract.sh validate issue.md
bash .claude/scripts/issue-contract.sh contract -
bash .claude/scripts/workflow-state.sh validate
bash .claude/scripts/workflow-state.sh status
bash .claude/scripts/workflow-state.sh get phase
bash .claude/scripts/workflow-state.sh --repo-root $FX_PD get phase
bash .claude/scripts/workflow-state.sh --repo-root $FX_PD status
bash .claude/scripts/workflow-state.sh counter review_attempts get
bash .claude/scripts/workflow-state.sh --repo-root $FX_PD counter impl_repair_attempts get
bash .claude/scripts/candidate.sh --repo-root $FX_PD fingerprint
bash .claude/scripts/candidate.sh manifest
bash .claude/scripts/candidate.sh scope --allowed .claude/scripts/** --protected backend/**
bash .claude/tests/run.sh
bash .claude/tests/run.sh safety
sh .claude/scripts/candidate.sh list
SCR

# ========================================================================
# 6b. Trusted-script argument abuse (issue) -> SAFETY_SHELL_COMMAND_DENIED
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "trusted-script arg abuse: $c" SAFETY_SHELL_COMMAND_DENIED "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<ABUSE
bash .claude/scripts/verify.sh --mode worktree --record .claude/x.json
bash .claude/scripts/verify.sh --mode worktree --record=/tmp/x
bash .claude/scripts/verify.sh --record rec.json
bash .claude/scripts/verify.sh --repo-root /other/repo --mode worktree
bash .claude/scripts/workflow-state.sh --repo-root /elsewhere validate
bash .claude/scripts/candidate.sh --repo-root ../other fingerprint
bash .claude/scripts/issue-contract.sh frobnicate issue.md
bash .claude/scripts/candidate.sh nuke
bash .claude/scripts/workflow-state.sh --repo-root $FX_PD rm-rf
bash .claude/tests/run.sh --weird
bash .claude/tests/run.sh a b
bash .claude/scripts/verify.sh --mode worktree --contract-file /etc/passwd
bash .claude/scripts/verify.sh --mode worktree --issue-number NaN
bash .claude/scripts/verify.sh --mode worktree --base-commit zzz
bash .claude/scripts/verify.sh --mode bogus
ABUSE
gd "trusted-script arg abuse: run-id with space" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'bash .claude/scripts/verify.sh --mode worktree --run-id a b')"
gd "trusted-script: bash with no script" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'bash')"
gd "trusted-script: bash -s" SAFETY_SHELL_COMMAND_DENIED \
  "issue" "$G_SH" "$(fx_bash_input 'bash -s .claude/tests/run.sh')"

# ========================================================================
# 6c. verify.sh is NEVER on the Claude Bash allowlist (Review Correction
#     Round 1). Every invocation — bare, --record, or any other argument —
#     is SAFETY_SHELL_COMMAND_DENIED, in both workflow modes.
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "verify.sh not Bash-allowlisted (issue): $c" SAFETY_SHELL_COMMAND_DENIED \
    "issue" "$G_SH" "$(fx_bash_input "$c")"
  gd "verify.sh not Bash-allowlisted (maintenance): $c" SAFETY_SHELL_COMMAND_DENIED \
    "framework-maintenance" "$G_SH" "$(fx_bash_input "$c")"
done <<VERIFY
bash .claude/scripts/verify.sh
bash .claude/scripts/verify.sh --mode worktree
bash .claude/scripts/verify.sh --mode worktree --contract-file issue.md
bash .claude/scripts/verify.sh --mode staged --reviewed-manifest rm.json
bash .claude/scripts/verify.sh --repo-root $FX_PD --mode worktree
bash .claude/scripts/verify.sh --record rec.json
bash .claude/scripts/verify.sh --help
sh .claude/scripts/verify.sh --mode worktree
VERIFY

# ========================================================================
# 6d. workflow-state.sh — read-only inspection is allowed, EVERY mutating
#     subcommand and EVERY stray flag / extra positional fails closed with
#     SAFETY_SHELL_COMMAND_DENIED. workflow-state mutation is owned by the
#     future deterministic control plane, not Claude's Bash tool.
# ========================================================================

while IFS= read -r c; do
  [ -n "$c" ] || continue
  ga "workflow-state read-only allowed: $c" "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<WFSOK
bash .claude/scripts/workflow-state.sh validate
bash .claude/scripts/workflow-state.sh status
bash .claude/scripts/workflow-state.sh get phase
bash .claude/scripts/workflow-state.sh get resume_phase
bash .claude/scripts/workflow-state.sh --repo-root $FX_PD validate
bash .claude/scripts/workflow-state.sh --repo-root=$FX_PD status
bash .claude/scripts/workflow-state.sh counter review_attempts get
bash .claude/scripts/workflow-state.sh counter verification_attempts get
sh .claude/scripts/workflow-state.sh validate
WFSOK

while IFS= read -r c; do
  [ -n "$c" ] || continue
  gd "workflow-state mutation/abuse denied: $c" SAFETY_SHELL_COMMAND_DENIED \
    "issue" "$G_SH" "$(fx_bash_input "$c")"
done <<WFSBAD
bash .claude/scripts/workflow-state.sh init --run-id r --issue-number 17
bash .claude/scripts/workflow-state.sh transition VERIFY_WORKTREE
bash .claude/scripts/workflow-state.sh transition PLAN
bash .claude/scripts/workflow-state.sh set-blocker CODE message
bash .claude/scripts/workflow-state.sh clear-blocker
bash .claude/scripts/workflow-state.sh counter review_attempts inc
bash .claude/scripts/workflow-state.sh counter impl_repair_attempts inc
bash .claude/scripts/workflow-state.sh set-pr --number 5 --url u
bash .claude/scripts/workflow-state.sh --repo-root $FX_PD transition REVIEW
bash .claude/scripts/workflow-state.sh --number 5
bash .claude/scripts/workflow-state.sh --run-id x validate
bash .claude/scripts/workflow-state.sh validate --force
bash .claude/scripts/workflow-state.sh --allowed-path x validate
bash .claude/scripts/workflow-state.sh get phase extra
bash .claude/scripts/workflow-state.sh get
bash .claude/scripts/workflow-state.sh status now
bash .claude/scripts/workflow-state.sh counter review_attempts
bash .claude/scripts/workflow-state.sh counter review_attempts get extra
bash .claude/scripts/workflow-state.sh frobnicate
bash .claude/scripts/workflow-state.sh
bash .claude/scripts/workflow-state.sh -h
bash .claude/scripts/workflow-state.sh --help
WFSBAD
gd "workflow-state mutation denied (maintenance): transition" SAFETY_SHELL_COMMAND_DENIED \
  "framework-maintenance" "$G_SH" "$(fx_bash_input 'bash .claude/scripts/workflow-state.sh transition VERIFY_WORKTREE')"

# --repo-root pointing at a symlink that resolves to the project dir -> ALLOW
PD_LINK_SRC="$(fx_pdir)"
LINK_ALIAS="$(mktemp -d "$TEST_TMP_ROOT/rralias.XXXXXX")/plink"
ln -s "$PD_LINK_SRC" "$LINK_ALIAS"
ga "trusted-script: --repo-root via equivalent symlink -> allowed" \
  "issue" "$G_SH" "$(fx_bash_input "bash .claude/scripts/candidate.sh --repo-root $LINK_ALIAS fingerprint")" "$PD_LINK_SRC"

# ========================================================================
# 7. worktree-create-guard.sh — direct offline tests
# ========================================================================

wcg_run() {
  local mode="$1" stdin="$2"
  local -a e=(env)
  [ "$mode" = "-unset-" ] && e+=(-u OMNIVISE_WORKFLOW_MODE)
  e+=("CLAUDE_PROJECT_DIR=$FX_PD")
  [ "$mode" != "-unset-" ] && e+=("OMNIVISE_WORKFLOW_MODE=$mode")
  printf '%s' "$stdin" | "${e[@]}" bash "$SAFETY_HOOKS_DIR/$G_WC"
}
# The guard is unconditional: mode, payload shape, and payload content never
# change the outcome.
for spec in "issue|{}" "framework-maintenance|{}" "-unset-|{}" "issue|not json at all" "issue|" "bogusmode|{}" "-unset-|" "framework-maintenance|garbage"; do
  m="${spec%%|*}"; s="${spec#*|}"
  assert_fail_code "worktree-create-guard deny ($spec)" SAFETY_WORKTREE_LIFECYCLE_DENIED wcg_run "$m" "$s"
done
run_capture wcg_run issue "garbage payload"
assert_eq "worktree-create-guard: stdout is byte-empty" "" "$OUT"
assert_ne "worktree-create-guard: exit is non-zero" "0" "$RC"

# MIN-5: the guard is standalone — it must not depend on guard-common.sh (or any
# other shared runtime file) and must still fail closed when copied out alone.
assert_not_contains "worktree-create-guard: sources no guard-common.sh" \
  "$(cat "$SAFETY_HOOKS_DIR/$G_WC")" "guard-common.sh"
LONE_WC="$(mktemp -d "$TEST_TMP_ROOT/lonewc.XXXXXX")"
cp "$SAFETY_HOOKS_DIR/$G_WC" "$LONE_WC/"
run_capture bash "$LONE_WC/$G_WC" </dev/null
assert_ne "worktree-create-guard: denies as a lone copy (no shared deps)" "0" "$RC"
assert_eq "worktree-create-guard: lone copy keeps stdout byte-empty" "" "$OUT"
run_capture bash "$LONE_WC/$G_WC" </dev/null
assert_contains "worktree-create-guard: lone copy still emits the stable code" \
  "$ERR" "SAFETY_WORKTREE_LIFECYCLE_DENIED"

# ========================================================================
# 8. guard-common internal-error / input paths
# ========================================================================

LONE="$(mktemp -d "$TEST_TMP_ROOT/lone.XXXXXX")"
cp "$SAFETY_HOOKS_DIR/$G_FW" "$SAFETY_HOOKS_DIR/$G_SH" "$LONE/"
lone_fw() { printf '%s' "$1" | env OMNIVISE_WORKFLOW_MODE=issue CLAUDE_PROJECT_DIR="$FX_PD" bash "$LONE/$G_FW"; }
lone_sh() { printf '%s' "$1" | env OMNIVISE_WORKFLOW_MODE=issue CLAUDE_PROJECT_DIR="$FX_PD" bash "$LONE/$G_SH"; }
assert_fail_code "guard-common unavailable -> framework guard INTERNAL_ERROR" SAFETY_INTERNAL_ERROR \
  lone_fw "$(fwe 'backend/x')"
assert_fail_code "guard-common unavailable -> shell guard INTERNAL_ERROR" SAFETY_INTERNAL_ERROR \
  lone_sh "$(fx_bash_input 'git status')"

# malformed stdin
assert_fail_code "framework guard: non-JSON stdin -> INPUT_INVALID" SAFETY_INPUT_INVALID \
  fx_guard issue "$G_FW" 'not json'
assert_fail_code "framework guard: empty stdin -> INPUT_INVALID" SAFETY_INPUT_INVALID \
  fx_guard issue "$G_FW" ''
assert_fail_code "framework guard: {} stdin -> INPUT_INVALID" SAFETY_INPUT_INVALID \
  fx_guard issue "$G_FW" '{}'
assert_fail_code "framework guard: tool_input without a path -> INPUT_INVALID" SAFETY_INPUT_INVALID \
  fx_guard issue "$G_FW" '{"tool_input":{}}'
assert_fail_code "shell guard: non-JSON stdin -> INPUT_INVALID" SAFETY_INPUT_INVALID \
  fx_guard issue "$G_SH" 'not json'
assert_fail_code "framework guard: control char in path -> INPUT_INVALID" SAFETY_INPUT_INVALID \
  fx_guard issue "$G_FW" "$(jq -cn "{tool_name:\"Edit\",tool_input:{file_path:\"a\u0001b\"}}")"

# required tool missing (jq present for `command -v` but failing) -> fail-closed
JQ_SHADOW="$(mktemp -d "$TEST_TMP_ROOT/jqshadow.XXXXXX")"
printf '#!/usr/bin/env bash\nexit 3\n' >"$JQ_SHADOW/jq"
chmod +x "$JQ_SHADOW/jq"
shadow_jq_fw() { printf '%s' "$1" | env OMNIVISE_WORKFLOW_MODE=issue CLAUDE_PROJECT_DIR="$FX_PD" PATH="$JQ_SHADOW:$PATH" bash "$SAFETY_HOOKS_DIR/$G_FW"; }
assert_fail_code "framework guard: broken jq -> fail-closed SAFETY_" "SAFETY_" \
  shadow_jq_fw "$(fwe 'backend/x')"

# ========================================================================
# 9. settings.json — structural validation & alternate-surface denies
# ========================================================================

assert_ok "settings.json: structural validation passes" \
  fx_validate_settings "$SAFETY_SETTINGS_FILE"
for v in not-json wrong-matcher missing-timeout bad-timeout no-bash \
         missing-worktree-hook missing-deny-monitor missing-deny-enterworktree one-pretooluse; do
  BAD="$(fx_settings_bad "$v")"
  assert_fail "settings.json: rejected malformed variant '$v'" \
    fx_validate_settings "$BAD" "$SAFETY_HOOKS_DIR"
done
for tool in EnterWorktree ExitWorktree Monitor PowerShell; do
  assert_ok "settings.json: permissions.deny contains $tool" \
    jq -e --arg t "$tool" '.permissions.deny | index($t)' "$SAFETY_SETTINGS_FILE"
done
assert_ok "settings.json: WorktreeCreate hook references worktree-create-guard.sh" \
  jq -e '.hooks.WorktreeCreate[0].hooks[0].command | contains("worktree-create-guard.sh")' "$SAFETY_SETTINGS_FILE"
assert_ok "settings.json: Bash matcher wired to shell-guard.sh" \
  jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command | contains("shell-guard.sh")] | any' "$SAFETY_SETTINGS_FILE"
assert_ok "settings.json: file/notebook matcher wired to framework-write-guard.sh" \
  jq -e '[.hooks.PreToolUse[] | select(.matcher=="Edit|Write|MultiEdit|NotebookEdit") | .hooks[0].command | contains("framework-write-guard.sh")] | any' "$SAFETY_SETTINGS_FILE"

# ========================================================================
# 10. Compatibility / no-mutation / isolation
# ========================================================================

# The guard classifies, never executes: a denied `git commit` leaves the
# disposable repo's HEAD and working tree untouched.
PD_NM="$(fx_pdir)"
NM_HEAD="$(git -C "$PD_NM" rev-parse HEAD)"
run_capture fx_guard issue "$G_SH" "$(fx_bash_input 'git commit -m x')" "$PD_NM"
assert_ne "no-mutation: denied git commit exits non-zero" "0" "$RC"
assert_eq "no-mutation: disposable repo HEAD unchanged" "$NM_HEAD" "$(git -C "$PD_NM" rev-parse HEAD)"
assert_eq "no-mutation: disposable repo working tree clean" "" "$(git -C "$PD_NM" status --porcelain)"

assert_eq "isolation: real repo branch unchanged" \
  "$REPO_BRANCH_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" rev-parse --abbrev-ref HEAD)"
assert_eq "isolation: real repo HEAD unchanged" \
  "$REPO_HEAD_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" rev-parse HEAD)"
assert_eq "isolation: real repo status unchanged" \
  "$REPO_STATUS_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" status --porcelain)"
assert_eq "isolation: real repo index unchanged" \
  "$REPO_INDEX_BEFORE" "$(git -C "$OMNIVISE_REPO_ROOT" diff --cached --name-only)"
