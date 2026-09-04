#!/usr/bin/env bash
#
# agent_fixtures.sh — helpers for the Issue #18 agent-definition suite
# (agents_test.sh). Parses the flat YAML frontmatter used by
# .claude/agents/*.md (a leading "---" line, "key: value" lines, a closing
# "---" line) without a YAML dependency, and validates it against an expected
# tool/model/effort contract. Used against both the three real #18 agent
# files and disposable malformed fixtures under $TEST_TMP_ROOT, so the same
# validator that passes the real files is proven to reject a bad one.
#
# Sourced explicitly from the top of agents_test.sh (run.sh does not
# auto-source lib/*, matching the lib/safety_fixtures.sh convention).
# $REPO_ROOT / $TEST_TMP_ROOT come from run.sh.

AGENTS_DIR="$REPO_ROOT/.claude/agents"

# _agent_frontmatter_block FILE — print the lines strictly between the first
# "---" line and the next "---" line. Prints nothing if the file does not
# start with "---" on line 1, or never closes the block — callers then see
# empty fields and fail closed rather than mis-parsing the body as frontmatter.
_agent_frontmatter_block() {
  local file="$1"
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---"    { exit }
    infm                    { print }
  ' "$file" 2>/dev/null
}

# agent_frontmatter_field FILE KEY — print the value of one top-level
# "key: value" frontmatter line (first match only). Empty if absent.
agent_frontmatter_field() {
  local file="$1" key="$2"
  _agent_frontmatter_block "$file" | sed -n "s/^${key}:[[:space:]]*//p" | head -n1
}

# agent_frontmatter_keys FILE — one top-level frontmatter key per line, in
# file order, duplicates included (a duplicate key is itself a shape a
# caller may want to reject).
agent_frontmatter_keys() {
  local file="$1"
  _agent_frontmatter_block "$file" \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*:' \
    | sed -E 's/^([A-Za-z0-9_]+):.*/\1/'
}

# _agent_normalize_csv CSV — trim, drop empties, sort, dedupe, rejoin with
# commas. Used to compare "tools" sets order-independently.
_agent_normalize_csv() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' \
    | sort -u \
    | tr '\n' ',' \
    | sed 's/,$//'
}

# agent_tools_set FILE — the file's "tools:" value as a normalized,
# order-independent set string (e.g. "Edit,Glob,Grep,Read,Write").
agent_tools_set() {
  local file="$1"
  _agent_normalize_csv "$(agent_frontmatter_field "$file" tools)"
}

# agent_frontmatter_key_set FILE — the file's frontmatter keys as a
# normalized, order-independent set string.
agent_frontmatter_key_set() {
  local file="$1"
  _agent_normalize_csv "$(agent_frontmatter_keys "$file" | tr '\n' ',')"
}

# The exact frontmatter grammar every #18 agent definition must use: no more,
# no fewer keys. Anything else (memory, isolation, mcpServers, hooks, skills,
# permissionMode, color, experimental, or an Agent-Teams-related key) fails
# this check by definition.
AGENT_REQUIRED_KEY_SET="description,effort,model,name,tools"

# validate_agent_definition FILE EXPECTED_TOOLS_CSV EXPECTED_MODEL EXPECTED_EFFORT
#   0 = the file exists, opens with "---", declares exactly the required key
#       set, has a non-empty name/description, and its tools/model/effort
#       match the expected values exactly (tools compared as a set).
#   1 = any of the above fails.
validate_agent_definition() {
  local file="$1" expected_tools="$2" expected_model="$3" expected_effort="$4"

  [ -f "$file" ] || return 1
  [ "$(head -n1 "$file" 2>/dev/null)" = "---" ] || return 1

  [ "$(agent_frontmatter_key_set "$file")" = "$AGENT_REQUIRED_KEY_SET" ] || return 1

  local name desc tools model effort
  name="$(agent_frontmatter_field "$file" name)"
  desc="$(agent_frontmatter_field "$file" description)"
  tools="$(agent_tools_set "$file")"
  model="$(agent_frontmatter_field "$file" model)"
  effort="$(agent_frontmatter_field "$file" effort)"

  [ -n "$name" ] || return 1
  [ -n "$desc" ] || return 1
  [ "$tools" = "$(_agent_normalize_csv "$expected_tools")" ] || return 1
  [ "$model" = "$expected_model" ] || return 1
  [ "$effort" = "$expected_effort" ] || return 1

  return 0
}

# agent_fixture_write NAME CONTENT — write CONTENT to a disposable
# $TEST_TMP_ROOT/agent-fixtures/NAME file and print its path. For malformed /
# over-permissioned negative-test fixtures only; never touches the real repo.
agent_fixture_write() {
  local name="$1" content="$2" dir file
  dir="$TEST_TMP_ROOT/agent-fixtures"
  mkdir -p "$dir"
  file="$dir/$name"
  printf '%s' "$content" >"$file"
  printf '%s' "$file"
}
