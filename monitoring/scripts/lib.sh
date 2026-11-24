# shellcheck shell=bash
#
# lib.sh — shared helpers for the monitoring validation scripts.
# Sourced, never executed. Callers must `set -euo pipefail` themselves.

# Variables below are consumed by the scripts that source this file.
# shellcheck disable=SC2034
MON_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_DIR="$(cd "$MON_SCRIPTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MON_DIR/.." && pwd)"
MON_TOOLS_DIR="${MON_TOOLS_DIR:-$MON_DIR/.tools}"
MON_CACHE_DIR="${MON_CACHE_DIR:-$MON_DIR/.cache}"
VERSIONS_FILE="${VERSIONS_FILE:-$MON_DIR/versions.yaml}"

# Project limit (not a Kubernetes limit) for the rendered Grafana dashboards ConfigMap.
# shellcheck disable=SC2034
DASHBOARD_CONFIGMAP_MAX_BYTES=$((512 * 1024))

log()  { printf '[monitoring] %s\n' "$*" >&2; }
warn() { printf '[monitoring] WARNING: %s\n' "$*" >&2; }
die()  { printf '[monitoring] ERROR: %s\n' "$*" >&2; exit 1; }

# Resolve a tool: prefer the pinned copy in .tools/, then PATH.
tool() {
  local name="$1"
  if [[ -x "$MON_TOOLS_DIR/bin/$name" ]]; then
    printf '%s\n' "$MON_TOOLS_DIR/bin/$name"
  elif command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  else
    die "required tool '$name' not found (run monitoring/scripts/install-tools.sh)"
  fi
}

# Read a scalar from the flat `tooling:` block of versions.yaml without yq.
tooling_value() {
  local key="$1" value
  value="$(awk -v key="$key" '
    /^tooling:[[:space:]]*$/ { in_block = 1; next }
    in_block && /^[^[:space:]#]/ { in_block = 0 }
    in_block && $1 == key ":" { print $2; exit }
  ' "$VERSIONS_FILE")"
  [[ -n "$value" ]] || die "tooling.$key missing in $VERSIONS_FILE"
  printf '%s\n' "$value"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# verify_sha256 FILE EXPECTED — fail closed on mismatch.
verify_sha256() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || { printf 'missing file: %s\n' "$file" >&2; return 1; }
  actual="$(sha256_of "$file")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'sha256 mismatch for %s: expected %s, got %s\n' "$file" "$expected" "$actual" >&2
    return 1
  fi
}

require_linux_amd64() {
  [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] \
    || die "pinned toolchain checksums exist for linux-amd64 only (got $(uname -s)/$(uname -m))"
}

# Flatten a multi-document `helm template` output into a JSON array of objects,
# expanding `kind: List` wrappers (the chart emits additional ServiceMonitors that way).
flatten_render() {
  local rendered="$1" yq jq
  yq="$(tool yq)"; jq="$(tool jq)"
  "$yq" -o=json -I=0 'select(. != null and .kind != null)' "$rendered" \
    | "$jq" -c 'if .kind == "List" then .items[] else . end' \
    | "$jq" -s '.'
}
