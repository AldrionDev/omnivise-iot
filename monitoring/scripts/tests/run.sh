#!/usr/bin/env bash
#
# tests/run.sh --chart STACK_TGZ --render-dir DIR
#
# Validator self-tests: each check must accept the real content and reject a
# deliberately broken variant for the stated reason. DIR holds <env>.json flattened
# renders produced by validate.sh.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$TESTS_DIR/../lib.sh"

chart="" render_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart) chart="$2"; shift 2 ;;
    --render-dir) render_dir="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -f "$chart" && -f "$render_dir/homelab.json" && -f "$render_dir/aws.json" ]] \
  || die "usage: run.sh --chart TGZ --render-dir DIR (with homelab.json and aws.json)"

JQ="$(tool jq)"; YQ="$(tool yq)"
FIX="$TESTS_DIR/fixtures"
S="$MON_SCRIPTS_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0 failed=0
ok()  { printf '  ok   %s\n' "$1" >&2; passed=$((passed + 1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; failed=$((failed + 1)); }

# expect_pass NAME CMD...
expect_pass() {
  local name="$1"; shift
  if "$@" >"$tmp/out" 2>&1; then ok "$name"; else bad "$name (expected success)"; sed 's/^/       /' "$tmp/out" >&2; fi
}
# expect_reject NAME REASON_SUBSTRING CMD... — must fail AND report the stated reason.
expect_reject() {
  local name="$1" reason="$2"; shift 2
  if "$@" >"$tmp/out" 2>&1; then
    bad "$name (expected rejection)"
  elif grep -qF -- "$reason" "$tmp/out"; then
    ok "$name"
  else
    bad "$name (rejected, but without reason '$reason')"; sed 's/^/       /' "$tmp/out" >&2
  fi
}

policy() { python3 "$S/promql_policy.py" --allowlist "$MON_DIR/metric-allowlist.txt" < "$1"; }
mutate() { "$JQ" "$2" "$render_dir/$1.json" > "$tmp/$3.json"; }
render_check() { "$S/check-render.sh" --env "$1" --objects "$2"; }

log "self-test: PromQL policy helper"
expect_pass "policy accepts supported constructs" policy "$FIX/promql-allowed.json"
for f in "$FIX"/promql-reject-*.json; do
  reason="$("$JQ" -r '.[0].reason' "$f")"
  "$JQ" '[.[] | {source, expr}]' "$f" > "$tmp/policy-input.json"
  expect_reject "policy rejects $(basename "$f" .json)" "$reason" policy "$tmp/policy-input.json"
done

log "self-test: generated content drift"
mkdir -p "$tmp/content/rules" "$tmp/content/dashboards"
cp "$MON_DIR"/rules/*.rules.yaml "$tmp/content/rules/"
cp "$MON_DIR"/dashboards/*.json "$tmp/content/dashboards/"
# shellcheck disable=SC2120,SC2119
gen() { "$S/render-content.sh" --rules-dir "$tmp/content/rules" --dashboards-dir "$tmp/content/dashboards" --out "$tmp/content/out.yaml" "$@"; }
gen >/dev/null 2>&1
expect_pass "drift check accepts a fresh render" gen --check
printf '# hand edit\n' >> "$tmp/content/out.yaml"
expect_reject "drift check rejects a hand-edited generated file" "out of date" gen --check
gen >/dev/null 2>&1
sed -i 's/> 0.05/> 0.5/' "$tmp/content/rules/backend.rules.yaml"
expect_reject "drift check rejects a rule change without regeneration" "out of date" gen --check

log "self-test: render contract"
for env in homelab aws; do
  expect_pass "$env render passes unmodified" render_check "$env" "$render_dir/$env.json"
done
mutate homelab '. + [{"apiVersion":"monitoring.coreos.com/v1","kind":"ServiceMonitor","metadata":{"name":"kube-prometheus-stack-kube-etcd","namespace":"monitoring"},"spec":{"endpoints":[{"port":"http-metrics"}],"selector":{}}}]' disabled-sm
expect_reject "rejects a ServiceMonitor for a disabled job" "rendered for disabled job kube-etcd" render_check homelab "$tmp/disabled-sm.json"
mutate aws '. + [{"apiVersion":"monitoring.coreos.com/v1","kind":"ServiceMonitor","metadata":{"name":"rogue","namespace":"monitoring"},"spec":{"endpoints":[{"port":"http"}],"selector":{}}}]' rogue-sm
expect_reject "rejects an unexpected ServiceMonitor" "unexpected ServiceMonitor rendered: rogue" render_check aws "$tmp/rogue-sm.json"
mutate homelab '(.[] | select(.kind == "Deployment" and .metadata.name == "kube-prometheus-stack-operator") | .spec.template.spec.containers[0].args) |= map(select(startswith("--prometheus-instance-namespaces=") | not))' operator-scope
expect_reject "rejects an operator not scoped to the monitoring namespace" "--prometheus-instance-namespaces is not scoped" render_check homelab "$tmp/operator-scope.json"
mutate aws '. + [{"apiVersion":"admissionregistration.k8s.io/v1","kind":"ValidatingWebhookConfiguration","metadata":{"name":"kube-prometheus-stack-admission"}}]' webhook
expect_reject "rejects an admission webhook" "admission WebhookConfiguration rendered" render_check aws "$tmp/webhook.json"
mutate aws '[.[] | select(.kind != "ServiceMonitor" or .metadata.name != "backend")]' missing-sm
expect_reject "rejects a missing expected ServiceMonitor" "expected ServiceMonitor missing: backend" render_check aws "$tmp/missing-sm.json"
mutate homelab '. + [{"apiVersion":"v1","kind":"Secret","metadata":{"name":"kube-prometheus-stack-grafana","namespace":"monitoring"},"data":{"admin-user":"YQ==","admin-password":"YQ=="}}]' grafana-secret
expect_reject "rejects a rendered Grafana admin Secret" "carries Grafana admin credentials" render_check homelab "$tmp/grafana-secret.json"
mutate homelab '(.[] | select(.kind == "Deployment" and .metadata.name == "kube-prometheus-stack-grafana") | .spec.template.spec.containers[] | select(.name == "grafana") | .env[] | select(.name == "GF_SECURITY_ADMIN_PASSWORD")) |= {"name":"GF_SECURITY_ADMIN_PASSWORD","value":"not-a-secret"}' grafana-env
expect_reject "rejects a plain-text Grafana admin password env" "GF_SECURITY_ADMIN_PASSWORD must be a secretKeyRef" render_check homelab "$tmp/grafana-env.json"
mutate aws '(.[] | select(.kind == "ConfigMap" and .metadata.name == "kube-prometheus-stack-grafana") | .data["grafana.ini"]) |= sub("\\[auth\\.anonymous\\]\\nenabled = false"; "[auth.anonymous]\nenabled = true")' grafana-anon
expect_reject "rejects anonymous Grafana access" "anonymous access" render_check aws "$tmp/grafana-anon.json"
mutate homelab '(.[] | select(.kind == "Deployment" and .metadata.name == "kube-prometheus-stack-kube-state-metrics") | .spec.template.spec.containers[0].resources) |= del(.limits)' no-limits
expect_reject "rejects a container without limits" "kube-state-metrics lacks limits.cpu, limits.memory" render_check homelab "$tmp/no-limits.json"
mutate aws '(.[] | select(.kind == "Prometheus") | .spec) |= del(.resources)' no-prom-resources
expect_reject "rejects a Prometheus without resources" "Prometheus kube-prometheus-stack-prometheus lacks" render_check aws "$tmp/no-prom-resources.json"
mutate homelab '(.[] | select(.kind == "ServiceMonitor" and .metadata.name == "backend") | .spec.endpoints[0].relabelings[0].replacement) |= "omnivise-backend"' job-mismatch
expect_reject "rejects an effective job mismatch" "effective job omnivise-backend != expected backend" render_check homelab "$tmp/job-mismatch.json"
mutate aws '(.[] | select(.kind == "ServiceMonitor" and .metadata.name == "kube-prometheus-stack-apiserver") | .spec.endpoints[0]) |= del(.relabelings)' job-underivable
expect_reject "rejects an underivable job (Service not rendered)" "effective job cannot be derived" render_check aws "$tmp/job-underivable.json"
mutate homelab '. + [{"apiVersion":"networking.k8s.io/v1","kind":"Ingress","metadata":{"name":"grafana","namespace":"monitoring"},"spec":{}}]' ingress
expect_reject "rejects an Ingress" "Ingress rendered" render_check homelab "$tmp/ingress.json"
mutate aws '(.[] | select(.kind == "Prometheus") | .spec.retention) |= "30d"' retention
expect_reject "rejects a wrong environment retention" "expected 3d for aws" render_check aws "$tmp/retention.json"

log "self-test: rule contract"
mkdir -p "$tmp/rules/tests"
cp "$MON_DIR"/rules/*.rules.yaml "$tmp/rules/"
cp "$MON_DIR"/rules/tests/*.test.yaml "$tmp/rules/tests/"
rules_check() { "$S/check-rules.sh" --rules-dir "$tmp/rules" --tests-dir "$tmp/rules/tests"; }
expect_pass "rule contract accepts the real rules" rules_check
"$YQ" -i 'del(.tests[] | select(.name == "BackendHighErrorRatio stays quiet below the 5% threshold" or .name == "BackendHighErrorRatio stays quiet with zero traffic (NaN ratio)"))' \
  "$tmp/rules/tests/backend.test.yaml"
expect_reject "rejects an alert without a non-firing test case" "BackendHighErrorRatio: no explicit non-firing test case" rules_check
cp "$FIX/domain.rules.yaml" "$tmp/rules/backend.rules.yaml"
cp "$FIX/domain.test.yaml" "$tmp/rules/tests/backend.test.yaml"
expect_reject "rejects a rule on a domain metric" "metric 'omnivise_sensor_reading_value' is not on the allowlist" rules_check
cp "$MON_DIR"/rules/*.rules.yaml "$tmp/rules/"; cp "$MON_DIR"/rules/tests/*.test.yaml "$tmp/rules/tests/"
sed -i 's/|prometheus-operator"/"/' "$tmp/rules/platform.rules.yaml"
expect_reject "rejects a TargetDown job set that drifts from expected-targets" "TargetDown jobs" rules_check

log "self-test: dashboard contract"
mkdir -p "$tmp/dash"
cp "$MON_DIR"/dashboards/*.json "$tmp/dash/"
"$JQ" '.panels[0].targets[0].expr = "avg(omnivise_sensor_reading_value)"' "$MON_DIR/dashboards/backend-red-jvm.json" > "$tmp/dash/backend-red-jvm.json"
expect_reject "rejects a dashboard panel on a domain metric" "metric 'omnivise_sensor_reading_value' is not on the allowlist" \
  "$S/check-dashboards.sh" --dashboards-dir "$tmp/dash"
"$JQ" '.panels[0].datasource.uid = "prometheus"' "$MON_DIR/dashboards/backend-red-jvm.json" > "$tmp/dash/backend-red-jvm.json"
expect_reject "rejects a hard-coded datasource uid" "datasource must be \${datasource}" \
  "$S/check-dashboards.sh" --dashboards-dir "$tmp/dash"

log "self-test: chart artifact integrity"
cp "$chart" "$tmp/tampered.tgz"
printf 'x' >> "$tmp/tampered.tgz"
expect_reject "rejects a tampered chart artifact" "sha256 mismatch" \
  "$S/fetch-chart.sh" --verify "$tmp/tampered.tgz" "$("$YQ" '.kubePrometheusStack.sha256' "$VERSIONS_FILE")"
expect_reject "render refuses a tampered chart artifact" "refusing to render" "$S/render.sh" homelab "$tmp/tampered.tgz"

printf '\n' >&2
log "self-tests: $passed passed, $failed failed"
[[ $failed -eq 0 ]] || die "validator self-tests failed"
