#!/usr/bin/env bash
#
# check-render.sh --env homelab|aws --objects FILE.json
#     [--expected FILE] [--rules-dir DIR] [--dashboards-dir DIR]
#
# Asserts the render contract for ONE environment against its flattened render
# (see lib.sh flatten_render). Prints each failure and exits non-zero on any.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

env="" objects="" expected="$MON_DIR/expected-targets.yaml"
rules_dir="$MON_DIR/rules" dashboards_dir="$MON_DIR/dashboards"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env="$2"; shift 2 ;;
    --objects) objects="$2"; shift 2 ;;
    --expected) expected="$2"; shift 2 ;;
    --rules-dir) rules_dir="$2"; shift 2 ;;
    --dashboards-dir) dashboards_dir="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$objects" && -f "$objects" ]] || die "--objects FILE is required"

# Environment retention contract (#146 homelab ~7d, #148 AWS ~3d).
case "$env" in
  homelab) retention=7d ;;
  aws) retention=3d ;;
  *) die "--env must be homelab or aws" ;;
esac

YQ="$(tool yq)"; JQ="$(tool jq)"
expected_json="$(E="$env" "$YQ" -o=json -I=0 'explode(.) | .environments[strenv(E)]' "$expected")"
[[ "$expected_json" != "null" ]] || die "no environment '$env' in $expected"

rules_json="{}"
for f in "$rules_dir"/*.rules.yaml; do
  rules_json="$("$JQ" -c --arg k "$(basename "$f" .rules.yaml)" --argjson v "$("$YQ" -o=json -I=0 '.' "$f")" \
    '. + {($k): $v}' <<<"$rules_json")"
done
dashboards_json="{}"
for f in "$dashboards_dir"/*.json; do
  dashboards_json="$("$JQ" -c --arg k "$(basename "$f" .json)" --slurpfile v "$f" \
    '. + {($k): $v[0]}' <<<"$dashboards_json")"
done

failures="$("$JQ" \
  --arg env "$env" --arg retention "$retention" \
  --argjson maxbytes "$DASHBOARD_CONFIGMAP_MAX_BYTES" \
  --argjson expected "$expected_json" \
  --argjson rules "$rules_json" \
  --argjson dashboards "$dashboards_json" \
  -f "$MON_SCRIPTS_DIR/render-checks.jq" "$objects")"

count="$("$JQ" 'length' <<<"$failures")"
if [[ "$count" -gt 0 ]]; then
  "$JQ" -r --arg env "$env" '.[] | "FAIL [\($env)] \(.)"' <<<"$failures" >&2
  die "render contract: $count failure(s) for $env"
fi
log "render contract OK for $env ($("$JQ" 'length' "$objects") objects)"
