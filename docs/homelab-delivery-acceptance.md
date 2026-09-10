# Homelab Delivery — First Successful Jenkins-Driven Delivery

## Purpose

This document records the first successful Jenkins-driven OmniVise IoT delivery
to the shared homelab k3s platform, executed end to end by the pipeline defined
in the repository `Jenkinsfile` (Homelab Delivery milestone, issues #60, #61,
#62).

It captures only runtime evidence that was actually observed during that
successful run. It is a factual acceptance record; it does not change any
architecture decision and does not modify the pipeline, Terraform, or
application code.

The reviewed manual reference remains `docs/homelab-deployment-smoke.md`
(issue #40). The accepted design remains
`docs/architecture/delivery-architecture.md`. This document reports that the
automated pipeline reproduced the non-destructive part of that proven manual
path.

---

## Delivered revision

```text
Jenkins job:     projects/omnivise-iot  /  branch: main
Git SHA:         6ce2089a290d034b55a5047adbb9ce858ad5ff41
Commit subject:  Merge pull request #79 from AldrionDev/fix/jenkins-deploy-target-evidence
DEPLOY_TARGET:   homelab
```

No Jenkins build number, run URL, or wall-clock timestamp is recorded here
because none was captured at the time of the run.

---

## Verified pipeline outcome

The run passed every stage of the pipeline in order.

### 1. Checkout & identify revision

- Exact checked-out revision resolved and frozen as the 40-character Git SHA
  above.
- `DEPLOY_TARGET` was `homelab`.

### 2. Homelab preflight

- The shared `homelab-preflight` capability passed (non-zero would have stopped
  the run before any registry work).

### 3. Release-set write-once precheck

- Release-set mode for this SHA was **BUILD**: none of the three exact-SHA
  manifests existed yet, so the pipeline built and published the full release
  set.

### 4. Build & publish images

- Exact-SHA `backend`, `frontend`, and `simulator` images were built once from
  the checked-out workspace using the repository Dockerfiles.
- All three were pushed to the homelab registry under their canonical
  `omnivise-iot/<component>:<git-sha>` references.
- Post-push Registry V2 re-probe confirmed, per component: the exact tag
  exists, the response was HTTP 200, and a `Docker-Content-Digest` header was
  present (digest-verified). Concrete digests are not recorded in this file.

### 5. Terraform init & validate

- `terraform init` (HCP cloud backend, workspace `omnivise-iot-k8s`, Local
  execution), `terraform validate`, and `terraform fmt -check -recursive`
  all passed.

### 6. Homelab deploy — plan, approve, apply

- Exactly one saved Terraform plan (`infra/homelab/tfplan`) was produced,
  bound to the least-privilege `omnivise-iot-deployer` identity and the frozen
  exact-SHA image references.
- Pre-approval evidence (release identity plus a read-only `terraform show` of
  the exact saved plan) rendered successfully.
- A human explicitly approved applying that exact saved plan.
- `terraform apply` consumed that saved plan — no re-plan.
- Apply result:

  ```text
  1 added, 3 changed, 0 destroyed
  ```

  The three changed resources were the backend, frontend, and sensor-simulator
  image references. The one added resource was the `mongodb-bootstrap` job.

### 7. Post-deploy smoke (non-destructive)

All checks were read-only against both the cluster and the application.

- **Workload readiness passed** for:

  ```text
  statefulset/mongodb
  deployment/backend
  deployment/frontend
  deployment/sensor-simulator
  ```

- **Exact running-image verification passed**: the live workload container
  images matched the frozen release-SHA references exactly.

- **ResourceQuota compatibility passed indirectly**: all intended workloads
  were admitted and reached their desired Ready replica count within the
  bounded wait (a quota-rejected pod never becomes Ready), and `terraform
  apply` itself succeeded. A direct read of the `ResourceQuota` object is not
  available to the least-privilege `omnivise-iot-deployer` identity and the
  RBAC was not widened; this is not a direct `ResourceQuota` object inspection.

- **HTTP smoke passed**:

  ```text
  GET /                              -> 200, root marker matched
  GET /api/sensors/latest?limit=1    -> 200, JSON array shape matched
  ```

- **WebSocket smoke passed**:

  ```text
  connected to ws://omnivise-iot.homelab.home.arpa/ws/sensors
  received a fresh, structurally valid sensor event after connection
  ```

  This exercised the full
  `sensor-simulator -> MongoDB rs0 -> Change Stream -> backend -> /ws/sensors -> Traefik`
  data path, not just a WebSocket handshake.

### 8. Post actions

- `infra/homelab/tfplan` was removed and the workspace was cleaned.

---

## Result

```text
Pipeline result:      SUCCESS
Rollback required:     no
Destructive smoke:     none used
```

The end state is a running OmniVise deployment on the homelab cluster at Git
SHA `6ce2089a290d034b55a5047adbb9ce858ad5ff41`.

The destructive #40 MongoDB pod-recreation persistence proof is deliberately
out of scope for the automated pipeline and was not performed here.

---

## Operational issue found during onboarding

The first automatic multibranch run of the pipeline **failed before the
approval gate**: the pre-approval evidence shell referenced `DEPLOY_TARGET`,
but that value is a Jenkins pipeline parameter rather than part of the
declarative `environment {}` block, so — unlike `GIT_SHA` and the `*_IMAGE`
references — it was not exported into the `sh` step automatically. Under
`set -eu` the unset variable failed the evidence step closed.

The hotfix explicitly scoped `params.DEPLOY_TARGET` into that one evidence
shell with `withEnv(["DEPLOY_TARGET=${params.DEPLOY_TARGET}"])` (merged as
PR #79). After the merge, the next controlled run completed successfully — the
run recorded in this document.

This was an application `Jenkinsfile` integration bug in how a pipeline
parameter was passed into a shell step. It was not a Jenkins platform defect.
