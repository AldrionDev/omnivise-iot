#!/usr/bin/env bash
#
# validate.sh — the repository-owned monitoring validation contract (#145).
# CI runs exactly this (after install-tools.sh); run it locally the same way.
#
#   1. fetch the pinned stack chart once and verify its sha256 (fetch-chart.sh)
#   2. generated content layer is up to date (render-content.sh --check)
#   3. per environment (homelab, aws), independently: helm template from the verified
#      local chart with base -> env -> generated/content, then the render contract
#   4. rules: promtool check/test, coverage, TargetDown job set, domain-metric policy
#   5. dashboards: JSON contract and domain-metric policy
#   6. versions: offline contract against the same verified chart
#   7. validator self-tests (negative fixtures must be rejected)

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for t in helm promtool yq jq; do tool "$t" >/dev/null; done
command -v python3 >/dev/null 2>&1 || die "python3 is required"

HELM="$(tool helm)"
helm_major="$("$HELM" version --template '{{.Version}}' | sed -E 's/^v([0-9]+).*/\1/')"
pinned_major="$(tooling_value helmVersion | cut -d. -f1)"
if [[ "$helm_major" != "$pinned_major" ]]; then
  warn "using Helm major $helm_major from $HELM; CI validates with pinned Helm $(tooling_value helmVersion) (run install-tools.sh)"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step() { log "== $*"; }

step "chart artifact"
chart="$("$MON_SCRIPTS_DIR/fetch-chart.sh" stack)"
log "verified chart: $chart"

step "generated content drift"
"$MON_SCRIPTS_DIR/render-content.sh" --check

for env in homelab aws; do
  step "render + contract: $env"
  "$MON_SCRIPTS_DIR/render.sh" "$env" "$chart" > "$work/$env.yaml"
  flatten_render "$work/$env.yaml" > "$work/$env.json"
  "$MON_SCRIPTS_DIR/check-render.sh" --env "$env" --objects "$work/$env.json"
done

step "rules"
"$MON_SCRIPTS_DIR/check-rules.sh"

step "dashboards"
"$MON_SCRIPTS_DIR/check-dashboards.sh"

step "versions (offline contract)"
"$MON_SCRIPTS_DIR/check-versions.sh" --offline-contract --chart "$chart"

step "validator self-tests"
"$MON_SCRIPTS_DIR/tests/run.sh" --chart "$chart" --render-dir "$work"

log "monitoring validation PASSED"
