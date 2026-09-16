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

**The GHCR publication capability described here is implemented and has now
been exercised against live Jenkins and live GHCR state. The observed runs
covered GHCR BUILD via an existing homelab exact-SHA release set, GHCR REUSE,
and the default homelab-only path with GHCR verification disabled. All
GHCR-focused Jenkins runs were stopped at the human Terraform approval gate;
no Terraform apply or Kubernetes mutation was performed during those
verification runs.**

## Status summary

| #   | Scenario                                                    | Status                                               |
| --- | ----------------------------------------------------------- | ---------------------------------------------------- |
| 1   | Manual read-only GHCR API spike                             | **Completed**                                        |
| 2   | GHCR BUILD path (Jenkins run)                               | **Completed**                                        |
| 3   | GHCR REUSE path (Jenkins run)                               | **Completed**                                        |
| 4   | Homelab REUSE + GHCR BUILD — pull-not-rebuild (Jenkins run) | **Completed**                                        |
| 5   | GHCR REUSE + homelab BUILD — pull-not-rebuild (Jenkins run) | **Completed**                                        |
| 6   | Partial / fail-closed GHCR state (manual, outside Jenkins)  | **Completed**                                        |
| 7   | Homelab regression (`ENABLE_GHCR_VERIFICATION=false`)       | **Partially verified**                               |
| 8   | No Kubernetes/Terraform mutation during GHCR verification   | **Completed for executed Jenkins verification runs** |

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

**Status: completed.**

A live Jenkins run was executed for trusted `main` at exact Git SHA:

```text
53a8b322700272fdd9c93415e1241f741f82296c
```

By the time GHCR verification was enabled for this SHA, the homelab registry
already contained the complete exact-SHA release set, while GHCR did not.

The Jenkins prechecks resolved:

```text
Homelab release-set precheck: REUSE
GHCR release-set precheck: BUILD
Artifact source: HOMELAB_REUSE
```

The pipeline therefore did not rebuild any image. Instead, it pulled the
existing homelab exact-SHA artifacts and used those pulled local images as the
source for GHCR publication.

Observed homelab source digests:

```text
backend:
  sha256:fdd3f28b80493b1286bd4551667a3da1cbac1dac8e45149d260de86c8e609a14

frontend:
  sha256:bf5a7c9a136be731f66a6d1499decf8670fc4d12bd9a4c8c8e6b54b0ed756899

simulator:
  sha256:3a4e0e24e8ac2a2f6a0bda9c7d45a5693e06f26877f849b443298c7fca1f3484
```

The following exact-SHA GHCR tags were then published:

```text
ghcr.io/aldriondev/omnivise-iot-backend:53a8b322700272fdd9c93415e1241f741f82296c
ghcr.io/aldriondev/omnivise-iot-frontend:53a8b322700272fdd9c93415e1241f741f82296c
ghcr.io/aldriondev/omnivise-iot-simulator:53a8b322700272fdd9c93415e1241f741f82296c
```

Observed GHCR post-push digests:

```text
backend:
  sha256:fdd3f28b80493b1286bd4551667a3da1cbac1dac8e45149d260de86c8e609a14

frontend:
  sha256:bf5a7c9a136be731f66a6d1499decf8670fc4d12bd9a4c8c8e6b54b0ed756899

simulator:
  sha256:3a4e0e24e8ac2a2f6a0bda9c7d45a5693e06f26877f849b443298c7fca1f3484
```

For this observed run, the homelab and GHCR manifest digests happened to be
equal for all three components. The implementation does not require or assert
cross-registry digest equality; the release invariant is exact Git SHA plus
no rebuild plus successful destination publication and verification.

The pipeline logged:

```text
GHCR BUILD: three exact-SHA images published and verified to GHCR for
53a8b322700272fdd9c93415e1241f741f82296c.
```

## 3. GHCR REUSE path (Jenkins run)

**Status: completed.**

A second Jenkins run was executed against the same trusted `main` SHA:

```text
53a8b322700272fdd9c93415e1241f741f82296c
```

At that point, both registries already contained the complete exact-SHA
release set.

The prechecks resolved:

```text
Homelab release-set precheck: REUSE
GHCR release-set precheck: REUSE
Artifact source: NONE
```

As expected, the following stages were skipped:

```text
Build images
Acquire GHCR source artifact
Acquire homelab source artifact from GHCR
Publish images (homelab)
Publish images (GHCR)
```

The pipeline reported:

```text
Homelab REUSE: all three omnivise-iot exact-SHA images already present for
53a8b322700272fdd9c93415e1241f741f82296c; build and push skipped.

GHCR REUSE: all three exact-SHA images already present in GHCR for
53a8b322700272fdd9c93415e1241f741f82296c; publish skipped.
```

This confirms write-once reuse behavior for an already complete exact-SHA
release set: no rebuild, no pull for republishing, and no push occurred.

## 4. Homelab REUSE + GHCR BUILD — pull-not-rebuild path (Jenkins run)

**Status: completed.**

This scenario was exercised directly during the first live GHCR publication
run for:

```text
53a8b322700272fdd9c93415e1241f741f82296c
```

Observed decision state:

```text
HOMELAB_RELEASE_ACTION = REUSE
GHCR_RELEASE_ACTION    = BUILD
ARTIFACT_SOURCE        = HOMELAB_REUSE
```

The `Build images` stage was skipped.

The pipeline then pulled the three already-published homelab exact-SHA images
and recorded their repository digests:

```text
backend:
  192.168.1.197:5000/omnivise-iot/backend@
  sha256:fdd3f28b80493b1286bd4551667a3da1cbac1dac8e45149d260de86c8e609a14

frontend:
  192.168.1.197:5000/omnivise-iot/frontend@
  sha256:bf5a7c9a136be731f66a6d1499decf8670fc4d12bd9a4c8c8e6b54b0ed756899

simulator:
  192.168.1.197:5000/omnivise-iot/simulator@
  sha256:3a4e0e24e8ac2a2f6a0bda9c7d45a5693e06f26877f849b443298c7fca1f3484
```

The pipeline explicitly logged:

```text
Pulled homelab exact-SHA artifacts as the GHCR publish source (no rebuild)
```

Those same pulled local image artifacts were then retagged and published to
GHCR under the canonical exact-SHA tags.

This verifies the intended asymmetric recovery/reuse case: if the homelab
release set exists but GHCR does not, Jenkins reuses the existing exact-SHA
artifacts and does not rebuild them.

## 5. GHCR REUSE + homelab BUILD — pull-not-rebuild path (Jenkins run)

**Status: completed.**

Verification used revision
`e1d354eca2a5a2c7ebc89555db387240fb864d2e`.

Before the run, the exact-SHA homelab release set was removed only after
confirming that each of its three manifest digests was referenced exclusively
by that revision's tag in the corresponding homelab repository. GHCR already
contained the complete exact-SHA release set.

Jenkins then observed:

```text
Homelab release-set precheck: BUILD
GHCR release-set precheck: REUSE
Artifact source: GHCR_REUSE
```

`Build images` was skipped. `Acquire homelab source artifact from GHCR` pulled
the existing exact-SHA GHCR images and reused them as the homelab publication
source; no rebuild occurred.

Observed source / publication digests were:

```text
backend   sha256:dcf3361f9714c428b56f48ed0b512fe69b705698406a15eb1c805e0e7dbb717c
frontend  sha256:c16a628a7992920287801e212d3f6485afb85d5fc4d7d48ab21cf74dac54ef1e
simulator sha256:696afdd7026404336eb551677377fbfdab5029e4cbf3a9f91a33e7e5a2cfbce3
```

The homelab publish completed successfully with the same digests, while the
GHCR publish stage was skipped because the GHCR release set was already in
`REUSE` state.

The run reached the saved Terraform-plan approval gate and was aborted there.
No Terraform apply or Kubernetes mutation was performed.

## 6. Partial / fail-closed GHCR state (manual, outside Jenkins)

**Status: completed.**

This scenario was exercised manually, outside Jenkins, using the same shared
GHCR manifest probe script that the production Jenkins pipeline calls:

```text
.github/scripts/ghcr-manifest-probe.sh
```

A deliberately synthetic, non-Git-commit 40-hex identifier was generated:

```text
01db74f29bea1fd94771a609baae923dba7c6214
```

Only the backend image was published to GHCR under this synthetic tag, using
the maintainer's own GitHub PAT classic credential with `write:packages`
permission. The Jenkins credential `ghcr-omnivise-iot-publisher` was not used.

The source backend image was:

```text
ghcr.io/aldriondev/omnivise-iot-backend:53a8b322700272fdd9c93415e1241f741f82296c
```

It was retagged and published as:

```text
ghcr.io/aldriondev/omnivise-iot-backend:01db74f29bea1fd94771a609baae923dba7c6214
```

Observed digest:

```text
sha256:fdd3f28b80493b1286bd4551667a3da1cbac1dac8e45149d260de86c8e609a14
```

No corresponding frontend or simulator tag was published for the synthetic
identifier.

The three component probes therefore produced:

```text
backend=PRESENT
frontend=ABSENT
simulator=ABSENT
```

The same aggregation rule used by the Jenkins GHCR precheck was then executed
manually against those three probe results.

Observed result:

```text
GHCR release-set precheck failed closed:
backend=PRESENT frontend=ABSENT simulator=ABSENT

exit_code=1
```

This confirms the intended fail-closed behavior: a partial release set is
neither classified as `BUILD` nor `REUSE`; the precheck terminates with a
non-zero exit code instead.

The production Jenkinsfile was not modified for this test, and no Jenkins job,
Terraform operation, Kubernetes mutation, or AWS/EKS operation was involved.

### Cleanup note

After the test, the GitHub Packages web UI showed the synthetic tag and the
real release tag attached to the same GHCR package version / manifest digest:

```text
01db74f29bea1fd94771a609baae923dba7c6214
53a8b322700272fdd9c93415e1241f741f82296c
```

Both referenced:

```text
sha256:fdd3f28b80493b1286bd4551667a3da1cbac1dac8e45149d260de86c8e609a14
```

The available GitHub Packages UI deletion action operated on the package
version rather than offering an unambiguous tag-only removal path. Deleting
that version would therefore risk removing the legitimate release tag as well.

The test tag was intentionally left in place rather than performing an
unsafe cleanup operation.

The maintainer PAT used for this verification did not include
`delete:packages`; this was deliberate and preserved the least-privilege
boundary established for the test.

## 7. Homelab regression

**Status: partially verified.**

A live Jenkins run was executed for trusted `main` with the default:

```text
ENABLE_GHCR_VERIFICATION=false
```

for exact Git SHA:

```text
53a8b322700272fdd9c93415e1241f741f82296c
```

Observed behavior:

```text
Homelab release-set precheck: REUSE
GHCR verification disabled (ENABLE_GHCR_VERIFICATION=false)
Artifact source: NONE
```

All GHCR-related stages were skipped, including the GHCR release-set precheck
and GHCR publication stage.

The homelab release set was reused without rebuild or republish:

```text
Homelab REUSE: all three omnivise-iot exact-SHA images already present for
53a8b322700272fdd9c93415e1241f741f82296c; build and push skipped.
```

Terraform initialization and planning continued normally, which demonstrates
that disabling GHCR verification does not block the existing homelab delivery
path.

The run was intentionally aborted at the human approval gate before
`terraform apply`. Therefore, the full deploy-and-smoke portion of the
homelab regression path was not re-executed as part of issue #121
verification.

For that reason, this scenario remains **partially verified** rather than
fully completed.

## 8. No Kubernetes/Terraform mutation during GHCR verification

**Status: completed for all executed Jenkins verification runs.**

All Jenkins verification runs used for sections 2, 3, 4, and 7 reached the
existing Terraform human approval gate after the GHCR/homelab release-set
logic completed.

The saved Terraform plan for the observed runs included changes such as:

```text
Plan: 2 to add, 3 to change, 0 to destroy.
```

However, the approval prompt was not accepted.

Instead, the runs were explicitly aborted at:

```text
Apply the exact saved Terraform plan infra/homelab/tfplan to the OmniVise
homelab k3s target?
```

No `terraform apply "tfplan"` execution occurred.

The pipeline cleanup then removed the saved local plan artifact:

```text
rm -f infra/homelab/tfplan
```

Accordingly, the GHCR verification activity performed for issue #121 caused:

```text
GHCR registry mutation:
  yes, where publication was intentionally under test

Homelab registry mutation:
  yes, during the initial exact-SHA homelab publication that preceded the
  GHCR BUILD acceptance case

Terraform apply:
  no

Kubernetes workload mutation:
  no

AWS/EKS mutation:
  no
```

This preserves the verification boundary for issue #121: GHCR release-set
publication and reuse behavior were exercised live, while Kubernetes and AWS
deployment mutation remained outside the verification scope.
