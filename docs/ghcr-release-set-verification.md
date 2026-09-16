# GHCR Release-Set Publication — Verification Record (Issue #121)

## Purpose

This document records the verification evidence for issue #121 (publish the
exact-SHA OmniVise release set to GHCR alongside the existing homelab
registry). It captures only evidence that was actually observed; it does not
change any architecture decision and does not modify the pipeline, Terraform,
or application code.

The accepted design remains
[`docs/architecture/delivery-architecture.md`](architecture/delivery-architecture.md)
and [`docs/aws-delivery-identity.md`](aws-delivery-identity.md). This document
reports how the GHCR publication mechanism introduced by issue #121 was
proven, independently of any AWS/EKS deployment (which remains issue #122).

**The GHCR publication capability described here is implemented and has
passed static/syntax checks. It has not been exercised against a live Jenkins
run or live GHCR state, except for the read-only API spike in section 1. Do
not treat any section below other than section 1 as executed evidence.**

## Status summary

| # | Scenario | Status |
| --- | --- | --- |
| 1 | Manual read-only GHCR API spike | **Completed** |
| 2 | GHCR BUILD path (Jenkins run) | Pending |
| 3 | GHCR REUSE path (Jenkins run) | Pending |
| 4 | Homelab REUSE + GHCR BUILD — pull-not-rebuild (Jenkins run) | Pending |
| 5 | GHCR REUSE + homelab BUILD — pull-not-rebuild (Jenkins run) | Pending |
| 6 | Partial / fail-closed GHCR state (manual, outside Jenkins) | Pending |
| 7 | Homelab regression (`ENABLE_GHCR_VERIFICATION=false`) | Pending |
| 8 | No Kubernetes/Terraform mutation during GHCR verification | Pending |

---

## 1. Manual GHCR API spike (completed, read-only)

Before any Jenkins-facing GHCR probing/publishing code was written, a manual,
read-only spike was run directly against live `ghcr.io`, using the
already-provisioned GHCR credential, to empirically confirm the Registry V2
challenge/token/manifest shapes the pipeline now depends on
(`.github/scripts/ghcr-manifest-probe.sh`). No push, no delete, no package
mutation was performed.

Observed behavior:

```text
Unauthenticated manifest request
  -> HTTP 401
  -> WWW-Authenticate: Bearer realm="https://ghcr.io/token",
                               service="ghcr.io",
                               scope="repository:<namespace>/<package>:pull"

Token request (valid PAT, classic, write:packages scope)
  -> https://ghcr.io/token
  -> HTTP 200
  -> JSON field: "token"

Token request (invalid PAT)
  -> HTTP 403
  -> JSON: {"errors":[{"code":"DENIED","message":"denied"}]}

Authenticated manifest request, nonexistent package/tag
  -> HTTP 404

Authenticated manifest request, existing package/tag
  -> HTTP 200
  -> content-type: application/vnd.oci.image.index.v1+json
  -> Docker-Content-Digest header present

Transport failure (e.g. timeout)
  -> curl exits non-zero (observed exit code 28 for a timeout)
```

Consequences for the implementation:

- The GHCR precheck and post-push verification both use the Registry V2
  Bearer-token exchange (not the GitHub REST Packages API, not `docker
  manifest inspect`), since this was confirmed to give an explicit,
  deterministic HTTP status per call.
- The token realm/service/scope shape is fixed for a given package, so
  `.github/scripts/ghcr-manifest-probe.sh` constructs the token request URL
  directly from `GHCR_NAMESPACE`/`GHCR_REGISTRY`/the package name, rather than
  parsing the `WWW-Authenticate` challenge header at runtime.
- Classification implemented in the shared script:

  ```text
  token request:    200 + non-empty "token" field -> continue
                     anything else                 -> FAIL CLOSED

  manifest request:  200 -> PRESENT
                      404 -> ABSENT
                      401 / 403 / 5xx / other / malformed / transport
                        failure (curl non-zero under set -eu) -> FAIL CLOSED

  post-push verify:  200 + non-empty Docker-Content-Digest -> PASS
                      anything else                        -> FAIL CLOSED
  ```

- The PAT is passed to the token request via a mode-0600 temporary netrc file
  (`curl --netrc-file`), never as a `curl -u`/`--user` argument, so it never
  appears in this process's argv. The short-lived Bearer token returned in
  exchange for it gets the same treatment for the manifest request: a
  separate mode-0600 temporary curl config file (`curl -K`) carries the
  `Authorization: Bearer` header, never a `curl -H` argument. Both mechanisms
  were added after the spike and have not themselves been exercised against a
  live GHCR call yet — that happens the first time section 2 or 3 below is
  actually run.
- Artifact identity across registries is preserved by never rebuilding an
  exact Git SHA that already exists in one registry — the existing images are
  pulled and the same pulled local image artifact is published to the other
  registry. Cross-registry manifest digests are logged as traceability
  evidence only; they are not asserted equal and may legitimately differ.

---

## 2. GHCR BUILD path (Jenkins run)

**Status: pending.** Not yet executed. This section will record, once a real
pipeline run with `ENABLE_GHCR_VERIFICATION=true` is executed against a Git
SHA never before published to GHCR: the resolved `GHCR_RELEASE_ACTION`, the
three pushed exact-SHA tags, and the three post-push `Docker-Content-Digest`
values logged by the pipeline.

## 3. GHCR REUSE path (Jenkins run)

**Status: pending.** Not yet executed. This section will record a re-run
against the same Git SHA from section 2, confirming `GHCR_RELEASE_ACTION =
REUSE` and that no build or push occurred.

## 4. Homelab REUSE + GHCR BUILD — pull-not-rebuild path (Jenkins run)

**Status: pending.** Not yet executed. This section will record a run where
the homelab release set already exists (`HOMELAB_RELEASE_ACTION = REUSE`) but
GHCR does not (`GHCR_RELEASE_ACTION = BUILD`, `ARTIFACT_SOURCE =
HOMELAB_REUSE`): confirmation that `Build images` was skipped, `Acquire GHCR
source artifact` pulled the existing homelab images instead, and the
resulting `SOURCE_*_DIGEST` / `Docker-Content-Digest` (GHCR) values logged for
traceability.

## 5. GHCR REUSE + homelab BUILD — pull-not-rebuild path (Jenkins run)

**Status: pending.** Not yet executed. This is the symmetric case to section
4: the GHCR release set already exists (`GHCR_RELEASE_ACTION = REUSE`) but
homelab does not (`HOMELAB_RELEASE_ACTION = BUILD`, `ARTIFACT_SOURCE =
GHCR_REUSE`). This section will record confirmation that `Build images` was
skipped, `Acquire homelab source artifact from GHCR` pulled the existing GHCR
images and retagged them to the canonical homelab refs instead of rebuilding,
and the resulting `SOURCE_*_DIGEST` / `Docker-Content-Digest` (homelab) values
logged for traceability. This proves artifact identity is preserved
symmetrically in both pull directions, not only homelab-to-GHCR.

## 6. Partial / fail-closed GHCR state (manual, outside Jenkins)

**Status: pending.** Not yet executed. Per
[`docs/architecture/delivery-architecture.md`](architecture/delivery-architecture.md)
section 9, the multibranch Jenkins job builds trusted `main` only, so this
scenario is exercised without a Jenkins job run at all: a deliberately
synthetic, non-Git-commit 40-hex identifier is used, exactly one component
(`omnivise-iot-backend`) is pushed to it manually with the maintainer's own
personal GHCR credentials (never the Jenkins `ghcr-omnivise-iot-publisher`
credential), and `.github/scripts/ghcr-manifest-probe.sh` — the identical
script the Jenkins stages call — is invoked directly against that identifier.
This section will record the resulting per-component classification (expected:
`backend=PRESENT, frontend=ABSENT, simulator=ABSENT`, fail-closed exit) and the
manual cleanup performed afterward through the GitHub Packages web UI.
`GIT_SHA = git rev-parse HEAD` in the production Jenkinsfile is not exercised
or altered by this procedure.

## 7. Homelab regression

**Status: pending.** Not yet executed. This section will record a normal
`main` pipeline run with `ENABLE_GHCR_VERIFICATION=false` (the default),
confirming the homelab BUILD/REUSE/publish/Terraform/smoke stages behave
exactly as before issue #121, and that all GHCR-related stages are skipped.

## 8. No Kubernetes/Terraform mutation during GHCR verification

**Status: pending.** For every GHCR-focused verification run above that does
involve a real Jenkins pipeline execution (sections 2–5, 7), the human
approval `input` step gates the only Terraform-apply/Kubernetes-affecting
stage in the pipeline; declining or aborting it, or simply not reaching it in
scope-limited replay runs, keeps those runs read-only against the cluster.
Section 6 involves no Jenkins job at all. This section will record the
specific evidence (approval declined / stage not reached) for whichever runs
are used to demonstrate sections 2–5 and 7.
