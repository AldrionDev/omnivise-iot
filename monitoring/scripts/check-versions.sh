#!/usr/bin/env bash
#
# check-versions.sh --offline-contract [--chart STACK_TGZ]
# check-versions.sh --verify-upstream
#
# --offline-contract (every CI run): versions.yaml schema, the pin table in
#   docs/monitoring-versions.md, the verified local stack chart's Chart.yaml
#   (version, appVersion, kubeVersion) against versions.yaml, and the EKS (and, once
#   known, homelab) Kubernetes target against the declared kubeVersion constraint.
#   Needs no network beyond the stack chart that the render already fetches.
#
# --verify-upstream (mandatory on any version bump and for acceptance evidence):
#   additionally fetches the pinned prometheus-operator-crds chart (sha256-verified),
#   compares appVersions, renders the stack's embedded CRD subchart and the standalone
#   CRD chart, and requires the same 10 CustomResourceDefinitions with identical
#   object content (YAML-normalised: comments, blank lines and separators ignored).

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

mode="" chart=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline-contract|--verify-upstream) mode="$1"; shift ;;
    --chart) chart="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$mode" ]] || die "usage: check-versions.sh --offline-contract [--chart TGZ] | --verify-upstream"

YQ="$(tool yq)"; HELM="$(tool helm)"; JQ="$(tool jq)"
DOC="$REPO_ROOT/docs/monitoring-versions.md"
EXPECTED_CRD_COUNT=10
errors=0
fail() { printf 'FAIL [versions] %s\n' "$*" >&2; errors=$((errors + 1)); }
v() { "$YQ" "$1" "$VERSIONS_FILE"; }

# --- versions.yaml schema --------------------------------------------------------
for key in .helmRelease.name .helmRelease.namespace; do
  [[ "$(v "$key")" =~ ^[a-z0-9-]+$ ]] || fail "$key must be a DNS label"
done
for c in kubePrometheusStack prometheusOperatorCrds; do
  [[ "$(v ".$c.chart")" =~ ^[a-z0-9-]+$ ]] || fail ".$c.chart missing"
  [[ "$(v ".$c.repositoryUrl")" =~ ^https:// ]] || fail ".$c.repositoryUrl must be an https URL"
  [[ "$(v ".$c.version")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail ".$c.version must be an exact version"
  [[ "$(v ".$c.appVersion")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail ".$c.appVersion must be an exact version"
  [[ "$(v ".$c.sha256")" =~ ^[0-9a-f]{64}$ ]] || fail ".$c.sha256 must be a sha256 hex digest"
done
for key in helmVersion prometheusVersion yqVersion; do
  [[ "$(tooling_value "$key")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "tooling.$key must be an exact version"
done
for key in helmSha256 prometheusSha256 yqSha256; do
  [[ "$(tooling_value "$key")" =~ ^[0-9a-f]{64}$ ]] || fail "tooling.$key must be a sha256 hex digest"
done
[[ "$(tooling_value helmVersion)" == 3.* ]] \
  || fail "tooling.helmVersion must stay on Helm 3 (the Terraform helm provider embeds the Helm 3 library)"

# --- documentation pin table ---------------------------------------------------------
for c in kubePrometheusStack prometheusOperatorCrds; do
  row="| \`$(v ".$c.repository")/$(v ".$c.chart")\`"
  version="$(v ".$c.version")"; app="$(v ".$c.appVersion")"
  grep -F "$row" "$DOC" | grep -F "\`$version\`" | grep -qF "\`$app\`" \
    || fail "docs/monitoring-versions.md pin table does not list $(v ".$c.chart") $version / $app"
done

# --- Kubernetes compatibility ----------------------------------------------------
# Only the ">=X.Y.Z-0" constraint form is understood; anything else fails closed.
satisfies() {
  local constraint="$1" target="$2" min
  min="$(sed -nE 's/^>=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)-0$/\1/p' <<<"$constraint")"
  [[ -n "$min" ]] || { printf 'unsupported kubeVersion constraint: %s\n' "$constraint" >&2; return 2; }
  [[ "$target" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { printf 'invalid target version: %s\n' "$target" >&2; return 2; }
  [[ "$target" =~ ^[0-9]+\.[0-9]+$ ]] && target="$target.0"
  [[ "$(printf '%s\n%s\n' "$min" "$target" | sort -V | head -1)" == "$min" ]]
}
constraint="$(v .kubernetesCompatibility.stackConstraint)"
satisfies "$constraint" "$(v .kubernetesCompatibility.eksTarget)" \
  || fail "eksTarget $(v .kubernetesCompatibility.eksTarget) does not satisfy $constraint"
homelab="$(v .kubernetesCompatibility.homelabTarget)"
if [[ "$homelab" != "null" ]]; then
  satisfies "$constraint" "$homelab" || fail "homelabTarget $homelab does not satisfy $constraint"
fi

# --- verified stack chart metadata --------------------------------------------------
[[ -n "$chart" ]] || chart="$("$MON_SCRIPTS_DIR/fetch-chart.sh" stack)"
verify_sha256 "$chart" "$(v .kubePrometheusStack.sha256)" || die "stack chart artifact is not the pinned one"

chart_meta() { tar -xzOf "$1" "$2/Chart.yaml" | "$YQ" "$3"; }
stack="$(v .kubePrometheusStack.chart)"
[[ "$(chart_meta "$chart" "$stack" .version)" == "$(v .kubePrometheusStack.version)" ]] \
  || fail "stack Chart.yaml version != versions.yaml"
[[ "$(chart_meta "$chart" "$stack" .appVersion)" == "$(v .kubePrometheusStack.appVersion)" ]] \
  || fail "stack Chart.yaml appVersion != versions.yaml"
[[ "$(chart_meta "$chart" "$stack" .kubeVersion)" == "$constraint" ]] \
  || fail "stack Chart.yaml kubeVersion '$(chart_meta "$chart" "$stack" .kubeVersion)' != stackConstraint '$constraint'"

if [[ "$mode" == "--offline-contract" ]]; then
  [[ $errors -eq 0 ]] || die "version contract: $errors failure(s)"
  log "version contract OK (offline): $stack $(v .kubePrometheusStack.version), kubeVersion $constraint, eksTarget $(v .kubernetesCompatibility.eksTarget)"
  exit 0
fi

# --- upstream CRD compatibility proof ---------------------------------------------
crds_chart="$("$MON_SCRIPTS_DIR/fetch-chart.sh" crds)"
crds="$(v .prometheusOperatorCrds.chart)"
[[ "$(chart_meta "$crds_chart" "$crds" .version)" == "$(v .prometheusOperatorCrds.version)" ]] \
  || fail "CRD Chart.yaml version != versions.yaml"
[[ "$(chart_meta "$crds_chart" "$crds" .appVersion)" == "$(v .prometheusOperatorCrds.appVersion)" ]] \
  || fail "CRD Chart.yaml appVersion != versions.yaml"
[[ "$(v .kubePrometheusStack.appVersion)" == "$(v .prometheusOperatorCrds.appVersion)" ]] \
  || fail "operator appVersion differs between the stack and the CRD chart"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$chart" -C "$work"
"$HELM" template stack-crds "$work/$stack/charts/crds" --include-crds > "$work/stack-crds.yaml"
"$HELM" template operator-crds "$crds_chart" --include-crds > "$work/operator-crds.yaml"

normalise() {
  "$YQ" -o=json -I=0 'select(.kind == "CustomResourceDefinition")' "$1" \
    | "$JQ" -cs 'sort_by(.metadata.name)'
}
normalise "$work/stack-crds.yaml" > "$work/stack.json"
normalise "$work/operator-crds.yaml" > "$work/operator.json"
stack_count="$("$JQ" 'length' "$work/stack.json")"; operator_count="$("$JQ" 'length' "$work/operator.json")"

printf 'chart pair: %s %s (%s) / %s %s (%s)\n' \
  "$stack" "$(v .kubePrometheusStack.version)" "$(v .kubePrometheusStack.appVersion)" \
  "$crds" "$(v .prometheusOperatorCrds.version)" "$(v .prometheusOperatorCrds.appVersion)"
printf 'stack embedded CRDs: %s, standalone CRD chart: %s\n' "$stack_count" "$operator_count"
"$JQ" -r '.[] | "  \(.metadata.name)  \(.metadata.annotations["operator.prometheus.io/version"] // "-")"' "$work/stack.json"

[[ "$stack_count" -eq $EXPECTED_CRD_COUNT ]] || fail "stack chart renders $stack_count CRDs, expected $EXPECTED_CRD_COUNT"
[[ "$operator_count" -eq $EXPECTED_CRD_COUNT ]] || fail "CRD chart renders $operator_count CRDs, expected $EXPECTED_CRD_COUNT"
if ! diff <("$JQ" -S . "$work/stack.json") <("$JQ" -S . "$work/operator.json") > "$work/crd.diff"; then
  fail "CRD object content differs ($(wc -l < "$work/crd.diff") diff lines); the pair is incompatible until explained"
  head -40 "$work/crd.diff" >&2
else
  printf 'CRD object content: identical (%s objects)\n' "$stack_count"
fi

[[ $errors -eq 0 ]] || die "upstream verification: $errors failure(s)"
log "upstream verification OK ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
