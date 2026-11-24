#!/usr/bin/env bash
#
# fetch-chart.sh — produce the single, sha256-verified local chart artifact that
# every render and version check uses.
#
#   fetch-chart.sh [stack|crds]     # default: stack; prints the verified .tgz path
#   fetch-chart.sh --verify FILE SHA256
#
# The chart is pulled once into monitoring/.cache/charts/<chart>-<version>.tgz.
# A cached file is reused only after its checksum is re-verified; a mismatch
# fails closed (the file is never silently replaced). No render may reference
# the remote repository directly.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ "${1:-}" == "--verify" ]]; then
  [[ $# -eq 3 ]] || die "usage: fetch-chart.sh --verify FILE SHA256"
  verify_sha256 "$2" "$3"
  exit
fi

case "${1:-stack}" in
  stack) key=kubePrometheusStack ;;
  crds)  key=prometheusOperatorCrds ;;
  *) die "usage: fetch-chart.sh [stack|crds] | --verify FILE SHA256" ;;
esac

YQ="$(tool yq)"
HELM="$(tool helm)"
chart="$("$YQ" -e ".$key.chart" "$VERSIONS_FILE")"
version="$("$YQ" -e ".$key.version" "$VERSIONS_FILE")"
repo_url="$("$YQ" -e ".$key.repositoryUrl" "$VERSIONS_FILE")"
sha="$("$YQ" -e ".$key.sha256" "$VERSIONS_FILE")"

dest_dir="$MON_CACHE_DIR/charts"
dest="$dest_dir/${chart}-${version}.tgz"
mkdir -p "$dest_dir"

if [[ -f "$dest" ]]; then
  verify_sha256 "$dest" "$sha" \
    || die "cached chart $dest does not match the pinned sha256; delete it deliberately to re-fetch"
  printf '%s\n' "$dest"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$HELM" pull "$chart" --repo "$repo_url" --version "$version" --destination "$work" >&2
pulled="$work/${chart}-${version}.tgz"
verify_sha256 "$pulled" "$sha" || die "downloaded $chart $version does not match the pinned sha256"
mv "$pulled" "$dest"
log "fetched and verified $chart $version"
printf '%s\n' "$dest"
