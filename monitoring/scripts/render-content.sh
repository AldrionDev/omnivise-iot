#!/usr/bin/env bash
#
# render-content.sh — the single injection mechanism for repository-owned rules
# and dashboards. Generates the chart values layer monitoring/values/generated/content.yaml:
#
#   additionalPrometheusRulesMap.<name>      <- monitoring/rules/<name>.rules.yaml (promtool format, verbatim)
#   grafana.dashboards.omnivise.<name>.json  <- monitoring/dashboards/<name>.json   (raw JSON string)
#
# Both CI and the Terraform roots consume the committed output as the last values
# layer (base.yaml -> <env>.yaml -> generated/content.yaml).
#
#   render-content.sh              # (re)write the generated file
#   render-content.sh --check      # fail if the committed file differs from a fresh render
#   Options: --rules-dir DIR --dashboards-dir DIR --out FILE  (used by self-tests)

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

check=false
rules_dir="$MON_DIR/rules"
dashboards_dir="$MON_DIR/dashboards"
out="$MON_DIR/values/generated/content.yaml"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=true; shift ;;
    --rules-dir) rules_dir="$2"; shift 2 ;;
    --dashboards-dir) dashboards_dir="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

YQ="$(tool yq)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
body="$work/body.yaml"
printf '{}\n' > "$body"

valid_key() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid content name '$1' (lowercase, digits, '-')"; }

mapfile -t rule_files < <(find "$rules_dir" -maxdepth 1 -type f -name '*.rules.yaml' | LC_ALL=C sort)
mapfile -t dashboard_files < <(find "$dashboards_dir" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
[[ ${#rule_files[@]} -gt 0 ]] || die "no rule files in $rules_dir"
[[ ${#dashboard_files[@]} -gt 0 ]] || die "no dashboards in $dashboards_dir"

for f in "${rule_files[@]}"; do
  key="$(basename "$f" .rules.yaml)"; valid_key "$key"
  K="$key" F="$f" "$YQ" -i '.additionalPrometheusRulesMap[strenv(K)] = load(strenv(F))' "$body"
done
for f in "${dashboard_files[@]}"; do
  key="$(basename "$f" .json)"; valid_key "$key"
  K="$key" F="$f" "$YQ" -i '.grafana.dashboards.omnivise[strenv(K)].json = (load_str(strenv(F)) | . style="literal")' "$body"
done
"$YQ" -i '... comments=""' "$body"

generated="$work/content.yaml"
{
  printf '# GENERATED - do not edit. Run monitoring/scripts/render-content.sh.\n'
  printf '# Sources: monitoring/rules/*.rules.yaml, monitoring/dashboards/*.json\n'
  cat "$body"
} > "$generated"

if $check; then
  if ! diff -u "$out" "$generated" >&2; then
    die "generated content is out of date: run monitoring/scripts/render-content.sh and commit the result"
  fi
  log "generated content is up to date"
else
  mkdir -p "$(dirname "$out")"
  cp "$generated" "$out"
  log "wrote $out"
fi
