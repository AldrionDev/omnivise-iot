#!/usr/bin/env bash
#
# check-dashboards.sh [--dashboards-dir DIR] [--allowlist FILE]
#
# Dashboard contract: valid JSON, stable unique uid, title, non-empty panels, the
# `${datasource}` template variable used by every panel and target, content minimums
# for the required dashboards, and the metric allowlist on every panel expression.
# The rendered ConfigMap size is checked by check-render.sh.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

dashboards_dir="$MON_DIR/dashboards" allowlist="$MON_DIR/metric-allowlist.txt"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dashboards-dir) dashboards_dir="$2"; shift 2 ;;
    --allowlist) allowlist="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

JQ="$(tool jq)"
# Required dashboards and the metric families each must reference.
declare -A REQUIRED=(
  [backend-red-jvm]='jetty_server_requests_seconds_ jvm_'
  [platform-health]='kube_ node_'
)

mapfile -t files < <(find "$dashboards_dir" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
[[ ${#files[@]} -ge 2 ]] || die "at least two dashboards are required in $dashboards_dir"

errors=0
fail() { printf 'FAIL [dashboards] %s\n' "$*" >&2; errors=$((errors + 1)); }

all_exprs="[]"
declare -A seen_uid=()
for f in "${files[@]}"; do
  name="$(basename "$f" .json)"
  if ! "$JQ" -e 'type == "object"' "$f" >/dev/null 2>&1; then fail "$name: not a valid JSON object"; continue; fi

  uid="$("$JQ" -r '.uid // ""' "$f")"
  [[ "$uid" =~ ^[a-z0-9-]{1,40}$ ]] || fail "$name: uid '$uid' must match ^[a-z0-9-]{1,40}$"
  if [[ -n "${seen_uid[$uid]:-}" ]]; then fail "$name: uid '$uid' duplicates ${seen_uid[$uid]}"; fi
  seen_uid[$uid]="$name"

  "$JQ" -e '(.title // "") != ""' "$f" >/dev/null || fail "$name: title is required"

  # Panels, including panels nested in rows.
  panels="$("$JQ" -c '[.panels[]? | ., (.panels[]?)] | map(select(.type != "row"))' "$f")"
  [[ "$("$JQ" 'length' <<<"$panels")" -gt 0 ]] || fail "$name: no panels"

  "$JQ" -e '[.templating.list[]? | select(.name == "datasource" and .type == "datasource" and .query == "prometheus")] | length == 1' \
    "$f" >/dev/null || fail "$name: a 'datasource' template variable of type prometheus is required"

  while IFS= read -r bad; do fail "$name: $bad"; done < <("$JQ" -r '
    .[] | . as $p
    | ( select(($p.datasource.uid // "") != "${datasource}") | "panel \($p.id) \"\($p.title)\": datasource must be ${datasource}" ),
      ( select(($p.targets // []) | length == 0) | "panel \($p.id) \"\($p.title)\": no targets" ),
      ( ($p.targets // [])[] | select((.datasource.uid // "") != "${datasource}" or (.expr // "") == "")
        | "panel \($p.id) \"\($p.title)\" target \(.refId): needs expr and datasource ${datasource}" )
  ' <<<"$panels")

  exprs="$("$JQ" -c --arg n "$name" '[.[] | . as $p | ($p.targets // [])[] | select(.expr != null)
          | {source: "dashboard \($n) panel \($p.id) \(.refId)", expr: .expr}]' <<<"$panels")"
  all_exprs="$("$JQ" -c --argjson e "$exprs" '. + $e' <<<"$all_exprs")"

  if [[ -n "${REQUIRED[$name]:-}" ]]; then
    for family in ${REQUIRED[$name]}; do
      "$JQ" -e --arg fam "$family" 'any(.[]; .expr | contains($fam))' <<<"$exprs" >/dev/null \
        || fail "$name: must contain panels querying ${family}* metrics"
    done
  fi
done

for required in "${!REQUIRED[@]}"; do
  [[ -f "$dashboards_dir/$required.json" ]] || fail "required dashboard $required.json is missing"
done

if [[ "$("$JQ" 'length' <<<"$all_exprs")" -gt 0 ]]; then
  python3 "$MON_SCRIPTS_DIR/promql_policy.py" --allowlist "$allowlist" <<<"$all_exprs" \
    || fail "metric allowlist policy violation"
fi

[[ $errors -eq 0 ]] || die "dashboard contract: $errors failure(s)"
log "dashboard contract OK (${#files[@]} dashboards)"
