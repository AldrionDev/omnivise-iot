#!/usr/bin/env bash
#
# render.sh ENV [CHART_TGZ] — render kube-prometheus-stack for one environment
# (homelab|aws) from the sha256-verified local chart artifact, using the contract
# merge order base.yaml -> ENV.yaml -> generated/content.yaml. Writes YAML to stdout.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

env="${1:-}"
[[ "$env" == "homelab" || "$env" == "aws" ]] || die "usage: render.sh homelab|aws [CHART_TGZ]"
chart="${2:-$("$MON_SCRIPTS_DIR/fetch-chart.sh" stack)}"

YQ="$(tool yq)"
stack_sha="$("$YQ" -e '.kubePrometheusStack.sha256' "$VERSIONS_FILE")"
"$MON_SCRIPTS_DIR/fetch-chart.sh" --verify "$chart" "$stack_sha" \
  || die "refusing to render: $chart is not the pinned, verified chart artifact"

release="$("$YQ" -e '.helmRelease.name' "$VERSIONS_FILE")"
namespace="$("$YQ" -e '.helmRelease.namespace' "$VERSIONS_FILE")"

"$(tool helm)" template "$release" "$chart" --namespace "$namespace" \
  -f "$MON_DIR/values/base.yaml" \
  -f "$MON_DIR/values/$env.yaml" \
  -f "$MON_DIR/values/generated/content.yaml"
