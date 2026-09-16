#!/usr/bin/env sh
# Shared GHCR Registry V2 manifest probe/verify script (issue #121).
#
# Single source of truth for:
#   - the Jenkins GHCR release-set write-once precheck;
#   - the Jenkins post-push GHCR digest verification;
#   - the manual partial-state fail-closed verification procedure
#     (docs/ghcr-release-set-verification.md), run directly against a
#     synthetic, non-Git-SHA identifier, entirely outside Jenkins.
#
# The Bearer token realm/service/scope shape used below was confirmed
# empirically against live ghcr.io before this script was written; see
# docs/ghcr-release-set-verification.md for the recorded evidence.
#
# Usage:
#   ghcr-manifest-probe.sh <precheck|verify> <package-name> <ref>
#
#   package-name must be one of: omnivise-iot-backend, omnivise-iot-frontend,
#   omnivise-iot-simulator (the approved GHCR package names).
#   ref is the exact-SHA tag to probe (40 lowercase hex characters — this
#   script does not care whether it came from `git rev-parse HEAD` or a
#   deliberately synthetic verification identifier; that distinction is the
#   caller's responsibility).
#
# Required environment:
#   GHCR_USERNAME   GHCR/GitHub username (e.g. AldrionDev)
#   GHCR_TOKEN      GitHub PAT (classic), write:packages scope. Never printed,
#                   never passed as a curl argument — a mode-0600 temporary
#                   netrc file carries it to the token endpoint instead, so
#                   it never appears in this process's argv. The short-lived
#                   Bearer token obtained in exchange for it gets the same
#                   treatment: it goes into a separate mode-0600 temporary
#                   curl config file, never a curl -H argument.
# Optional environment:
#   GHCR_NAMESPACE  GHCR namespace/owner (default: aldriondev)
#   GHCR_REGISTRY   Registry host (default: ghcr.io)
#
# precheck mode: prints "STATUS=PRESENT" or "STATUS=ABSENT" and exits 0.
#   Any authentication failure, transport failure, or unexpected/malformed
#   response exits non-zero (fail closed) with a diagnostic on stderr.
#
# verify mode: requires the manifest to be PRESENT with a non-empty
#   Docker-Content-Digest header. Prints "STATUS=PRESENT" and
#   "DIGEST=<digest>" and exits 0 only in that case. Absence, a missing
#   digest, or any ambiguous response exits non-zero (fail closed).
#
# No dependency on jq: token/digest extraction uses sed/awk only, matching
# the existing homelab Registry V2 probe's toolchain in the Jenkinsfile.

set -eu
set +x

usage() {
    echo "usage: ghcr-manifest-probe.sh <precheck|verify> <package-name> <ref>" >&2
    exit 2
}

MODE="${1:-}"
PACKAGE="${2:-}"
REF="${3:-}"
[ -n "$MODE" ] && [ -n "$PACKAGE" ] && [ -n "$REF" ] || usage

case "$MODE" in
    precheck|verify) ;;
    *)
        echo "ghcr-manifest-probe: unknown mode '$MODE' (expected precheck|verify)" >&2
        exit 2
        ;;
esac

case "$PACKAGE" in
    omnivise-iot-backend|omnivise-iot-frontend|omnivise-iot-simulator) ;;
    *)
        echo "ghcr-manifest-probe: unsupported package '$PACKAGE' (expected omnivise-iot-backend|omnivise-iot-frontend|omnivise-iot-simulator)" >&2
        exit 2
        ;;
esac

if ! echo "$REF" | grep -qE '^[0-9a-f]{40}$'; then
    echo "ghcr-manifest-probe: ref '$REF' is not exactly 40 lowercase hex characters" >&2
    exit 2
fi

: "${GHCR_USERNAME:?GHCR_USERNAME is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"
GHCR_NAMESPACE="${GHCR_NAMESPACE:-aldriondev}"
GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io}"

# Restrict permissions on every file this script creates from here on —
# applies before the netrc file below is written, not just to it.
umask 077

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

token_body="$tmp_dir/token.json"
manifest_headers="$tmp_dir/manifest.headers"
netrc_file="$tmp_dir/netrc"

# The PAT is never passed as a curl argument (curl -u/--user would put it in
# this process's argv, visible to anything that can read /proc or `ps` on the
# Jenkins agent). Instead it goes into a mode-0600 temporary netrc file,
# removed by the EXIT trap above along with the rest of tmp_dir.
printf 'machine %s\nlogin %s\npassword %s\n' "$GHCR_REGISTRY" "$GHCR_USERNAME" "$GHCR_TOKEN" > "$netrc_file"
chmod 600 "$netrc_file"

# --- Token acquisition -------------------------------------------------
# repository:<namespace>/<package>:pull is sufficient for both existence
# probing and manifest-digest reads; no write scope is ever requested here.
token_http_code=$(curl -sS --max-time 15 \
    --netrc-file "$netrc_file" \
    -o "$token_body" \
    -w '%{http_code}' \
    "https://${GHCR_REGISTRY}/token?service=${GHCR_REGISTRY}&scope=repository:${GHCR_NAMESPACE}/${PACKAGE}:pull")

if [ "$token_http_code" != "200" ]; then
    echo "ghcr-manifest-probe: token request failed for $PACKAGE: HTTP $token_http_code" >&2
    exit 1
fi

token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$token_body" | head -n1)
if [ -z "$token" ]; then
    echo "ghcr-manifest-probe: token response for $PACKAGE had no non-empty 'token' field" >&2
    exit 1
fi

# The Bearer token is short-lived and scoped, but it is still a credential —
# same discipline as the PAT above: never a curl argument (visible in argv),
# instead a mode-0600 temporary curl config file holding only the
# Authorization header, removed by the tmp_dir EXIT trap. Any embedded double
# quote is escaped defensively, though GHCR tokens are plain JWT-shaped
# base64url text and never contain one.
bearer_header_file="$tmp_dir/bearer.cfg"
token_escaped=$(printf '%s' "$token" | sed 's/"/\\"/g')
printf 'header = "Authorization: Bearer %s"\n' "$token_escaped" > "$bearer_header_file"
chmod 600 "$bearer_header_file"

# --- Authenticated, OCI-aware manifest request --------------------------
# Same four Accept types already proven by the homelab Registry V2 probe in
# the Jenkinsfile, so an existing OCI manifest/index is never misclassified
# as missing. Accept is non-secret and stays as ordinary -H arguments; only
# the Authorization header comes from the config file above.
manifest_http_code=$(curl -sS --max-time 15 \
    -D "$manifest_headers" -o /dev/null -w '%{http_code}' \
    -K "$bearer_header_file" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${GHCR_REGISTRY}/v2/${GHCR_NAMESPACE}/${PACKAGE}/manifests/${REF}")

case "$manifest_http_code" in
    200) status=PRESENT ;;
    404) status=ABSENT ;;
    *)
        echo "ghcr-manifest-probe: unexpected manifest response for $PACKAGE:$REF: HTTP $manifest_http_code" >&2
        exit 1
        ;;
esac

digest=""
if [ "$status" = PRESENT ]; then
    digest=$(tr -d '\r' < "$manifest_headers" | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | head -n1)
fi

if [ "$MODE" = precheck ]; then
    echo "STATUS=$status"
    exit 0
fi

# verify mode: only PRESENT with a digest is acceptable — absence here means
# a push that should have succeeded did not actually land, which must fail
# closed rather than be treated as a benign "not built yet" state.
if [ "$status" != PRESENT ] || [ -z "$digest" ]; then
    echo "ghcr-manifest-probe: post-push verify failed for $PACKAGE:$REF: status=$status digest='${digest:-<none>}'" >&2
    exit 1
fi

echo "STATUS=$status"
echo "DIGEST=$digest"
