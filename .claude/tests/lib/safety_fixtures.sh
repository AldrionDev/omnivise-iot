#!/usr/bin/env bash
#
# safety_fixtures.sh — helpers for the Issue #17 safety-boundary suite
# (safety_guard_test.sh). Kept separate from lib/fixtures.sh so the existing
# workflow-core fixtures and their assertions are untouched.
#
# Everything here is offline and disposable: temporary Git repositories under
# $TEST_TMP_ROOT, crafted hook payloads, and direct guard-script invocations.
# The real repository lifecycle is never touched.
#
# Sourced explicitly from the top of safety_guard_test.sh (run.sh does not
# auto-source lib/*). $REPO_ROOT / $TESTS_DIR / $TEST_TMP_ROOT / $OMNIVISE_REPO_ROOT
# come from run.sh.

SAFETY_HOOKS_DIR="$REPO_ROOT/.claude/hooks"
SAFETY_SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"

# Optional PATH prefix for a single fx_guard call (used to shadow `git`).
FX_GUARD_PATH=""

# --------------------------------------------------------------------------
# Disposable project directories
# --------------------------------------------------------------------------

# fx_pdir — a fresh committed Git repo with a .claude/ skeleton; prints its path.
fx_pdir() {
  local d
  d="$(mktemp -d "$TEST_TMP_ROOT/safety-pd.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email fixture@example.invalid
  git -C "$d" config user.name fixture
  git -C "$d" config commit.gpgsign false
  mkdir -p "$d/.claude/scripts" "$d/.claude/hooks" "$d/.claude/tests/lib" \
    "$d/backend/src" "$d/frontend/src" "$d/docs" "$d/src"
  printf 'x\n'    >"$d/.claude/scripts/verify.sh"
  printf 'x\n'    >"$d/.claude/tests/state_test.sh"
  printf 'seed\n' >"$d/README.md"
  printf 'seed\n' >"$d/backend/src/Main.java"
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm seed >/dev/null
  printf '%s' "$d"
}

# fx_worktree REPO NAME — add a linked worktree on a new branch; prints its path.
fx_worktree() {
  local r="$1" name="$2" wt
  wt="$(mktemp -d "$TEST_TMP_ROOT/safety-wt.XXXXXX")"
  rmdir "$wt"
  git -C "$r" worktree add -q -b "wt/$name" "$wt" >/dev/null 2>&1
  printf '%s' "$wt"
}

# Shared default project dir for the majority of cases.
FX_PD="$(fx_pdir)"

# --------------------------------------------------------------------------
# Hook payloads
# --------------------------------------------------------------------------

# fx_hook_input TOOL INPUT_JSON — a PreToolUse-shaped payload.
fx_hook_input() {
  jq -cn --arg t "$1" --argjson ti "$2" \
    '{hook_event_name:"PreToolUse", tool_name:$t, tool_input:$ti}'
}

fx_edit_input()     { fx_hook_input "${2:-Edit}" "$(jq -cn --arg p "$1" '{file_path:$p}')"; }
fx_notebook_input() { fx_hook_input NotebookEdit "$(jq -cn --arg p "$1" '{notebook_path:$p}')"; }
fx_bash_input()     { fx_hook_input Bash "$(jq -cn --arg c "$1" '{command:$c}')"; }

# --------------------------------------------------------------------------
# Guard invocation
# --------------------------------------------------------------------------

# fx_guard MODE SCRIPT JSON [PDIR]
#   MODE == "-unset-"  -> OMNIVISE_WORKFLOW_MODE is unset for the child
#   MODE == ""         -> OMNIVISE_WORKFLOW_MODE="" (explicitly empty)
#   otherwise          -> OMNIVISE_WORKFLOW_MODE=MODE
#   PDIR defaults to $FX_PD.
#   FX_GUARD_PATH, when non-empty, is prepended to PATH for this call only.
# Runs as a function so assert_ok / assert_fail_code / run_capture can call it.
fx_guard() {
  local mode="$1" script="$2" json="$3" pdir="${4:-$FX_PD}"
  local -a e=(env)
  [ "$mode" = "-unset-" ] && e+=(-u OMNIVISE_WORKFLOW_MODE)
  [ -n "$FX_GUARD_PATH" ] && e+=("PATH=$FX_GUARD_PATH:$PATH")
  e+=("CLAUDE_PROJECT_DIR=$pdir")
  [ "$mode" != "-unset-" ] && e+=("OMNIVISE_WORKFLOW_MODE=$mode")
  printf '%s' "$json" | "${e[@]}" bash "$SAFETY_HOOKS_DIR/$script"
}

# --------------------------------------------------------------------------
# settings.json validation
# --------------------------------------------------------------------------

# fx_validate_settings FILE [HOOKS_DIR]
#   Structural + referential validation of a project-local settings.json.
#   HOOKS_DIR defaults to "<dir of FILE>/hooks". Returns 0 when valid.
fx_validate_settings() {
  local f="$1"
  local hooks_dir="${2:-$(dirname "$f")/hooks}"

  [ -f "$f" ] || { echo "settings file not found: $f" >&2; return 1; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "not a JSON object" >&2; return 1; }

  jq -e '.hooks.PreToolUse | type == "array" and length == 2' "$f" >/dev/null 2>&1 \
    || { echo "hooks.PreToolUse must be an array of 2 entries" >&2; return 1; }
  jq -e '[.hooks.PreToolUse[].matcher] | sort == ["Bash","Edit|Write|MultiEdit|NotebookEdit"]' "$f" >/dev/null 2>&1 \
    || { echo "hooks.PreToolUse matchers are not exactly {Bash, Edit|Write|MultiEdit|NotebookEdit}" >&2; return 1; }

  jq -e '.hooks.WorktreeCreate | type == "array" and length >= 1' "$f" >/dev/null 2>&1 \
    || { echo "hooks.WorktreeCreate must be a non-empty array" >&2; return 1; }

  jq -e '
    [ .hooks.PreToolUse[].hooks[], .hooks.WorktreeCreate[].hooks[] ] as $h
    | ($h | length) >= 3
      and ($h | all(.[];
            .type == "command"
            and .timeout == 10
            and (.command | type == "string")
            and (.command | startswith("bash \""))
            and (.command | contains(".claude/hooks/"))))
  ' "$f" >/dev/null 2>&1 \
    || { echo "a hook entry is not a well-formed command hook (type/timeout/command)" >&2; return 1; }

  jq -e '
    (.permissions.deny // []) as $d
    | ($d | length) >= 4
      and (["EnterWorktree","ExitWorktree","Monitor","PowerShell"] | all(.[]; . as $x | $d | index($x)))
  ' "$f" >/dev/null 2>&1 \
    || { echo "permissions.deny must contain EnterWorktree, ExitWorktree, Monitor, PowerShell" >&2; return 1; }

  [ -d "$hooks_dir" ] || { echo "hooks dir not found: $hooks_dir" >&2; return 1; }
  local cmd script base
  while IFS= read -r cmd; do
    script="$(printf '%s' "$cmd" | grep -oE '\.claude/hooks/[A-Za-z0-9._-]+\.sh' | head -n1)"
    [ -n "$script" ] || { echo "cannot extract a hook script path from: $cmd" >&2; return 1; }
    base="${script#.claude/hooks/}"
    [ -f "$hooks_dir/$base" ] || { echo "referenced hook script is missing: $base" >&2; return 1; }
    bash -n "$hooks_dir/$base" 2>/dev/null || { echo "referenced hook script fails bash -n: $base" >&2; return 1; }
  done < <(jq -r '[ .hooks.PreToolUse[].hooks[], .hooks.WorktreeCreate[].hooks[] ][].command' "$f")

  return 0
}

# fx_settings_bad VARIANT — write a deliberately broken settings.json under
# $TEST_TMP_ROOT and print its path. The real .claude/hooks dir is used for the
# referential checks so the structural defect is what fails.
fx_settings_bad() {
  local variant="$1" f base
  f="$(mktemp "$TEST_TMP_ROOT/bad-settings.XXXXXX.json")"
  base="$SAFETY_SETTINGS_FILE"
  case "$variant" in
    not-json)
      printf '{ this is not json\n' >"$f" ;;
    wrong-matcher)
      jq '.hooks.PreToolUse[0].matcher = "Edit"' "$base" >"$f" ;;
    missing-timeout)
      jq 'del(.hooks.PreToolUse[0].hooks[0].timeout)' "$base" >"$f" ;;
    bad-timeout)
      jq '.hooks.PreToolUse[0].hooks[0].timeout = 60' "$base" >"$f" ;;
    no-bash)
      jq '.hooks.PreToolUse[1].hooks[0].command = "sh \"${CLAUDE_PROJECT_DIR}/.claude/hooks/shell-guard.sh\""' "$base" >"$f" ;;
    missing-worktree-hook)
      jq 'del(.hooks.WorktreeCreate)' "$base" >"$f" ;;
    missing-deny-monitor)
      jq '.permissions.deny -= ["Monitor"]' "$base" >"$f" ;;
    missing-deny-enterworktree)
      jq '.permissions.deny -= ["EnterWorktree"]' "$base" >"$f" ;;
    one-pretooluse)
      jq '.hooks.PreToolUse = [ .hooks.PreToolUse[0] ]' "$base" >"$f" ;;
    *)
      printf 'fx_settings_bad: unknown variant: %s\n' "$variant" >&2; return 1 ;;
  esac
  printf '%s' "$f"
}
