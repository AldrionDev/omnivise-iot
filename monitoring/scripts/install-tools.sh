#!/usr/bin/env bash
#
# install-tools.sh — install the pinned monitoring validation toolchain
# (helm, promtool, yq) into monitoring/.tools/bin, verifying every download
# against the sha256 pinned in monitoring/versions.yaml `tooling:`.
#
# Idempotent: a tool whose recorded version and archive checksum already match
# the pins is not downloaded again. Used identically by CI and local runs.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_linux_amd64
for cmd in curl tar sha256sum awk; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required to install the toolchain"
done

BIN_DIR="$MON_TOOLS_DIR/bin"
STAMP_DIR="$MON_TOOLS_DIR/stamps"
mkdir -p "$BIN_DIR" "$STAMP_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stamp records "<version> <sha256>" of the verified artifact a binary came from.
is_current() {
  local name="$1" version="$2" sha="$3"
  [[ -x "$BIN_DIR/$name" && -f "$STAMP_DIR/$name" ]] \
    && [[ "$(cat "$STAMP_DIR/$name")" == "$version $sha" ]]
}

download_verified() {
  local url="$1" sha="$2" out="$3"
  curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url"
  verify_sha256 "$out" "$sha" || die "checksum verification failed for $url"
}

install_helm() {
  local version sha work
  version="$(tooling_value helmVersion)"; sha="$(tooling_value helmSha256)"
  if is_current helm "$version" "$sha"; then log "helm $version already installed"; return; fi
  work="$(mktemp -d -p "$WORK")"
  download_verified "https://get.helm.sh/helm-v${version}-linux-amd64.tar.gz" "$sha" "$work/helm.tgz"
  tar -xzf "$work/helm.tgz" -C "$work" linux-amd64/helm
  install -m 0755 "$work/linux-amd64/helm" "$BIN_DIR/helm"
  printf '%s %s\n' "$version" "$sha" > "$STAMP_DIR/helm"
  log "installed helm $version"
}

install_promtool() {
  local version sha work dir
  version="$(tooling_value prometheusVersion)"; sha="$(tooling_value prometheusSha256)"
  if is_current promtool "$version" "$sha"; then log "promtool $version already installed"; return; fi
  work="$(mktemp -d -p "$WORK")"
  dir="prometheus-${version}.linux-amd64"
  download_verified \
    "https://github.com/prometheus/prometheus/releases/download/v${version}/${dir}.tar.gz" \
    "$sha" "$work/prometheus.tgz"
  tar -xzf "$work/prometheus.tgz" -C "$work" "$dir/promtool"
  install -m 0755 "$work/$dir/promtool" "$BIN_DIR/promtool"
  printf '%s %s\n' "$version" "$sha" > "$STAMP_DIR/promtool"
  log "installed promtool $version"
}

install_yq() {
  local version sha work
  version="$(tooling_value yqVersion)"; sha="$(tooling_value yqSha256)"
  if is_current yq "$version" "$sha"; then log "yq $version already installed"; return; fi
  work="$(mktemp -d -p "$WORK")"
  download_verified \
    "https://github.com/mikefarah/yq/releases/download/v${version}/yq_linux_amd64" \
    "$sha" "$work/yq"
  install -m 0755 "$work/yq" "$BIN_DIR/yq"
  printf '%s %s\n' "$version" "$sha" > "$STAMP_DIR/yq"
  log "installed yq $version"
}

install_helm
install_promtool
install_yq
log "toolchain ready in $BIN_DIR"
