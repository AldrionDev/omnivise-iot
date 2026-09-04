#!/usr/bin/env bash
# agents_test.sh — Issue #18 Claude planning/implementation/review agent
# definitions.
#
# Every case inspects the real .claude/agents/*.md files (never mutates
# them), or exercises the shared validator against disposable malformed
# fixtures under $TEST_TMP_ROOT. The framework-write-guard section reuses the
# real Issue #17 hook script and fixtures rather than re-implementing guard
# behaviour. All offline; no network; the real repository Git lifecycle is
# never touched.

# shellcheck source=lib/agent_fixtures.sh
. "$TESTS_DIR/lib/agent_fixtures.sh"
# shellcheck source=lib/safety_fixtures.sh
. "$TESTS_DIR/lib/safety_fixtures.sh"

suite "agents"

PLANNER="$AGENTS_DIR/planner.md"
IMPLEMENTER="$AGENTS_DIR/implementer.md"
REVIEWER="$AGENTS_DIR/reviewer.md"

GIT_LIFECYCLE_PROHIBITION="must not stage, commit, push, merge, or create pull requests"

# ========================================================================
# 1. Planner
# ========================================================================

assert_file_exists "planner.md exists at the expected project-local path" "$PLANNER"

assert_ok "planner.md: valid definition (tools/model/effort)" \
  validate_agent_definition "$PLANNER" "Read, Grep, Glob" "sonnet" "high"

assert_eq "planner.md: tools set is exactly Read,Grep,Glob" \
  "Glob,Grep,Read" "$(agent_tools_set "$PLANNER")"
assert_not_contains "planner.md: no Bash" "$(agent_tools_set "$PLANNER")" "Bash"
assert_not_contains "planner.md: no Edit" "$(agent_tools_set "$PLANNER")" "Edit"
assert_not_contains "planner.md: no Write" "$(agent_tools_set "$PLANNER")" "Write"
assert_not_contains "planner.md: no Agent" "$(agent_tools_set "$PLANNER")" "Agent"
assert_not_contains "planner.md: no Task" "$(agent_tools_set "$PLANNER")" "Task"

PLANNER_BODY="$(cat "$PLANNER")"
assert_contains "planner.md: references AGENTS.md as authoritative" "$PLANNER_BODY" "AGENTS.md"
assert_contains "planner.md: authority language present" "$PLANNER_BODY" "authoritative"
assert_contains "planner.md: never claims implementation completion" \
  "$PLANNER_BODY" "never claims implementation completion"

# ========================================================================
# 2. Implementer
# ========================================================================

assert_file_exists "implementer.md exists at the expected project-local path" "$IMPLEMENTER"

assert_ok "implementer.md: valid definition (tools/model/effort)" \
  validate_agent_definition "$IMPLEMENTER" "Read, Grep, Glob, Edit, Write" "sonnet" "high"

assert_eq "implementer.md: tools set is exactly Read,Grep,Glob,Edit,Write" \
  "Edit,Glob,Grep,Read,Write" "$(agent_tools_set "$IMPLEMENTER")"
assert_not_contains "implementer.md: no Bash" "$(agent_tools_set "$IMPLEMENTER")" "Bash"
assert_not_contains "implementer.md: no Agent" "$(agent_tools_set "$IMPLEMENTER")" "Agent"
assert_not_contains "implementer.md: no Task" "$(agent_tools_set "$IMPLEMENTER")" "Task"

IMPLEMENTER_BODY="$(cat "$IMPLEMENTER")"
assert_contains "implementer.md: Allowed Changed Paths discipline is explicit" \
  "$IMPLEMENTER_BODY" "Allowed Changed Paths"
assert_contains "implementer.md: Protected Paths discipline is explicit" \
  "$IMPLEMENTER_BODY" "Protected Paths"
assert_contains "implementer.md: self-review is not verification" \
  "$IMPLEMENTER_BODY" "self-review is not verification"
assert_contains "implementer.md: git lifecycle prohibition present" \
  "$IMPLEMENTER_BODY" "$GIT_LIFECYCLE_PROHIBITION"

# ========================================================================
# 3. Reviewer
# ========================================================================

assert_file_exists "reviewer.md exists at the expected project-local path" "$REVIEWER"

assert_ok "reviewer.md: valid definition (tools/model/effort)" \
  validate_agent_definition "$REVIEWER" "Read, Grep, Glob" "opus" "high"

assert_eq "reviewer.md: tools set is exactly Read,Grep,Glob" \
  "Glob,Grep,Read" "$(agent_tools_set "$REVIEWER")"
assert_not_contains "reviewer.md: no Bash" "$(agent_tools_set "$REVIEWER")" "Bash"
assert_not_contains "reviewer.md: no Edit" "$(agent_tools_set "$REVIEWER")" "Edit"
assert_not_contains "reviewer.md: no Write" "$(agent_tools_set "$REVIEWER")" "Write"
assert_not_contains "reviewer.md: no Agent" "$(agent_tools_set "$REVIEWER")" "Agent"
assert_not_contains "reviewer.md: no Task" "$(agent_tools_set "$REVIEWER")" "Task"

assert_eq "reviewer.md: model is opus" "opus" "$(agent_frontmatter_field "$REVIEWER" model)"
assert_eq "reviewer.md: effort is high" "high" "$(agent_frontmatter_field "$REVIEWER" effort)"

# least-privilege, not a "fresh context" claim: memory is simply outside the
# required five-key grammar. Checked both via the exact key set (below) and
# directly here, since it is the specific field platform behaviour attaches
# extra Read/Write/Edit grants to.
assert_not_contains "reviewer.md: no memory key" \
  "$(agent_frontmatter_keys "$REVIEWER")" "memory"

REVIEWER_BODY="$(cat "$REVIEWER")"
assert_contains "reviewer.md: fresh dispatch language present" "$REVIEWER_BODY" "fresh"
assert_contains "reviewer.md: independence language present" "$REVIEWER_BODY" "independent"
assert_contains "reviewer.md: implementer reasoning excluded as evidence" \
  "$REVIEWER_BODY" "implementer reasoning and self-review must not be treated as evidence of correctness"
assert_contains "reviewer.md: complete-candidate inspection required" \
  "$REVIEWER_BODY" "complete current candidate"
assert_contains "reviewer.md: git lifecycle prohibition present" \
  "$REVIEWER_BODY" "$GIT_LIFECYCLE_PROHIBITION"

STANDARDS_LINE="$(grep -n 'Standards review' "$REVIEWER" | head -n1 | cut -d: -f1)"
SPEC_LINE="$(grep -n 'Specification review' "$REVIEWER" | head -n1 | cut -d: -f1)"
if [ -n "$STANDARDS_LINE" ] && [ -n "$SPEC_LINE" ] && [ "$STANDARDS_LINE" -lt "$SPEC_LINE" ]; then
  _pass "reviewer.md: Standards review precedes Specification review"
else
  _fail "reviewer.md: Standards review precedes Specification review" \
    "Standards line=${STANDARDS_LINE:-<absent>} Spec line=${SPEC_LINE:-<absent>}"
fi

assert_contains "reviewer.md: CHANGES_REQUIRED verdict defined" "$REVIEWER_BODY" "CHANGES_REQUIRED"
assert_contains "reviewer.md: PASS verdict defined" "$REVIEWER_BODY" "\`PASS\`"
assert_contains "reviewer.md: Critical severity referenced" "$REVIEWER_BODY" "Critical"
assert_contains "reviewer.md: Major severity referenced" "$REVIEWER_BODY" "Major"
assert_contains "reviewer.md: Minor severity referenced" "$REVIEWER_BODY" "Minor"

# ========================================================================
# 4. Cross-agent: frontmatter grammar, no Agent Teams surface, no lifecycle
#    tools, shared prohibition wording. Scoped only to the three #18 agent
#    files and their own disposable fixtures — no repository-global state
#    (settings.json included) is read or asserted here.
# ========================================================================

for f in "$PLANNER" "$IMPLEMENTER" "$REVIEWER"; do
  n="$(basename "$f")"
  assert_eq "$n: frontmatter key set is exactly name,description,tools,model,effort" \
    "$AGENT_REQUIRED_KEY_SET" "$(agent_frontmatter_key_set "$f")"
  for forbidden in EnterWorktree ExitWorktree Monitor PowerShell Agent Task Bash; do
    assert_not_contains "$n: no $forbidden tool" "$(agent_tools_set "$f")" "$forbidden"
  done
  assert_contains "$n: git lifecycle prohibition present" \
    "$(cat "$f")" "$GIT_LIFECYCLE_PROHIBITION"
done

# --- negative cases: the SAME validator used above must reject a bad file ---

OVERPERMISSIONED="$(agent_fixture_write "overpermissioned.md" '---
name: bad
description: has bash
tools: Read, Grep, Glob, Bash
model: sonnet
effort: high
---

body
')"
assert_fail "validate_agent_definition rejects an over-permissioned fixture (Bash in tools)" \
  validate_agent_definition "$OVERPERMISSIONED" "Read, Grep, Glob" "sonnet" "high"

NO_TOOLS_LINE="$(agent_fixture_write "no-tools.md" '---
name: bad
description: no tools line at all (implicit all-tools)
model: sonnet
effort: high
---

body
')"
assert_fail "validate_agent_definition rejects a fixture missing the tools key" \
  validate_agent_definition "$NO_TOOLS_LINE" "Read, Grep, Glob" "sonnet" "high"

EXTRA_KEY="$(agent_fixture_write "extra-key.md" '---
name: bad
description: has an extra memory key
tools: Read, Grep, Glob
model: sonnet
effort: high
memory: project
---

body
')"
assert_fail "validate_agent_definition rejects a fixture with an extra frontmatter key" \
  validate_agent_definition "$EXTRA_KEY" "Read, Grep, Glob" "sonnet" "high"

# ========================================================================
# 5. Real Issue #17 hook integration: the three agent files' own paths must
#    be classified "framework" by the actual framework-write-guard.sh, i.e.
#    the safety boundary already introduced by #17 treats .claude/agents/**
#    as framework-maintenance content, denied in issue mode, allowed only
#    under OMNIVISE_WORKFLOW_MODE=framework-maintenance.
# ========================================================================

assert_fail_code "framework-write-guard denies a write into .claude/agents/planner.md in issue mode" \
  SAFETY_FRAMEWORK_MUTATION_DENIED \
  fx_guard "issue" "framework-write-guard.sh" "$(fx_edit_input '.claude/agents/planner.md' Write)"

assert_ok "framework-write-guard allows a write into .claude/agents/planner.md in framework-maintenance mode" \
  fx_guard "framework-maintenance" "framework-write-guard.sh" "$(fx_edit_input '.claude/agents/planner.md' Write)"

assert_fail_code "framework-write-guard denies a write into .claude/tests/agents_test.sh in issue mode" \
  SAFETY_FRAMEWORK_MUTATION_DENIED \
  fx_guard "issue" "framework-write-guard.sh" "$(fx_edit_input '.claude/tests/agents_test.sh' Edit)"
