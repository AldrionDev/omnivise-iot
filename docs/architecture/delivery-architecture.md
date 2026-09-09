# OmniVise IoT Delivery Architecture Plan

**Status:** Accepted
**Scope:** Homelab Delivery now; AWS EKS delivery later
**Purpose:** Preserve the agreed delivery architecture and the design constraints that must remain stable as the project evolves.

## 1. Goal

Automate the already-proven OmniVise homelab deployment workflow with Jenkins while keeping the design simple enough to extend later to AWS EKS without rewriting the delivery pipeline.

The long-term delivery target selection is:

```text
DEPLOY_TARGET = homelab | aws | both
```

The current **Homelab Delivery** milestone implements only the `homelab` target.

The future AWS work adds `aws` and `both`.

There will be **no separate `PUSH_TARGET` parameter**. `DEPLOY_TARGET` controls both image publication and deployment.

## 2. High-Level Delivery Model

CI and CD remain separated.

```text
Developer
   |
   v
GitHub pull request
   |
   v
GitHub Actions CI
- tests
- lint/static validation
- application build checks
   |
   v
merge to main
   |
   v
Jenkins delivery pipeline
- identify exact Git SHA
- build release images once
- publish selected target artifacts
- Terraform saved plan
- human approval
- apply exact saved plan
- bounded post-deploy verification
```

GitHub Actions is the intended pull-request CI gate. This pattern is already
established by HomeStreamLab, but OmniVise does not currently have the equivalent
GitHub Actions workflow yet. Creating the OmniVise GitHub Actions CI workflow
belongs to the Homelab Delivery milestone if it is still absent.

Until that workflow exists, this document does not imply that `main` is already
protected by OmniVise GitHub Actions CI.

Jenkins is the post-merge delivery system. Once the GitHub Actions CI workflow
exists, Jenkins must not duplicate that CI. The long-term CI/CD separation is
unchanged: GitHub Actions owns pull-request CI, Jenkins owns post-merge delivery.

## 3. Core Artifact Identity

Every release is identified by the exact 40-character Git commit SHA.

The Git SHA is:

- resolved once from the checked-out revision;
- validated as a full 40-character hexadecimal commit id;
- used as the immutable image tag;
- propagated into Terraform image inputs;
- shown in the human approval step;
- re-asserted against the live workload after deployment.

The delivery provenance chain is:

```text
Git commit
  -> locally built image
  -> exact-SHA registry tag
  -> Terraform image input
  -> saved Terraform plan
  -> human-approved exact plan
  -> live workload
```

Mutable tags such as `latest` are not authoritative release identifiers.

## 4. Build-Once Principle

Application images are built once per Git SHA.

They must not be rebuilt independently for different deployment targets.

Long-term model:

```text
same Git SHA
    |
    v
build images once
    |
    +--> homelab registry
    |
    +--> GHCR
```

For `DEPLOY_TARGET=both`, the same locally built artifacts are tagged and pushed to both registries.

This preserves artifact identity across environments.

## 5. Deployment Target Model

### 5.1 `homelab`

```text
Jenkins
  -> local homelab registry
  -> Terraform homelab root
  -> k3s
```

### 5.2 `aws` — future

```text
Jenkins
  -> GHCR
  -> Terraform AWS root
  -> EKS
```

### 5.3 `both` — future

```text
same Git SHA / same locally built images
   |
   +--> local homelab registry --> homelab Terraform --> k3s
   |
   +--> GHCR -------------------> AWS Terraform ------> EKS
```

Homelab and AWS are independent deployment units.

There is no cross-target transactional rollback. If one target succeeds and the other fails, the successful deployment is not automatically rolled back.

## 6. Registry Strategy

### Homelab

The homelab target uses the existing local homelab registry.

### AWS

The AWS target will use GitHub Container Registry (GHCR).

### Explicit non-goals

The AWS design will **not** use Amazon ECR.

This is a portfolio/demo project and introducing ECR would add unnecessary infrastructure and lifecycle management.

## 7. Registry Publication Contract

Publication is fail-closed and write-once at the pipeline level.

For every selected registry, Jenkins checks the complete OmniVise application image set for the current Git SHA.

Expected states:

```text
all exact-SHA tags absent
    -> BUILD / PUBLISH

all exact-SHA tags present
    -> REUSE

partial presence
unexpected registry response
transport/authentication ambiguity
    -> FAIL CLOSED
```

For OmniVise, the component set is treated as one release set:

- backend
- frontend
- simulator

Here `simulator` is the registry/image repository path segment; `sensor-simulator`
is the Kubernetes Deployment/workload name. This naming difference does not change
any runtime naming.

The Registry V2 checks must be OCI-aware. They must not depend on an overly restrictive Docker-only manifest `Accept` header that can misclassify an existing OCI manifest as missing.

Post-push verification must confirm that each expected exact-SHA image exists and returns a registry digest.

## 8. Jenkins Pipeline Shape

The current Homelab Delivery implementation should remain simple and readable.

Do not introduce a generic framework or complicated Groovy target abstraction merely to anticipate future AWS support.

Preferred structure:

```text
Checkout / Identify Revision

Homelab Preflight

Release Publication
  -> Homelab registry publication
  -> GHCR publication             # future conditional branch

Delivery
  -> Homelab
       - Terraform init/validate
       - saved plan
       - pre-approval evidence
       - human approval
       - exact-plan apply
       - post-deploy verification

  -> AWS                           # future conditional branch
       - Terraform init/validate
       - saved plan
       - human approval
       - exact-plan apply
       - post-deploy verification
```

Adding the future AWS branch should be an extension, not a rewrite.

## 9. Jenkins Trigger and Branch Model

Follow the proven shared Jenkins platform model:

- multibranch pipeline;
- trusted `main` branch only;
- Jenkinsfile from the application repository;
- periodic repository scan;
- manual repository scan available;
- no requirement for an inbound webhook to the LAN-only Jenkins controller;
- concurrent builds disabled.

The Homelab Delivery milestone should onboard OmniVise into the existing `local-jenkins-platform` project registry rather than create a bespoke Jenkins job implementation.

## 10. Terraform Is the Authoritative Deployment Mechanism

Jenkins must not manage application resources through ad-hoc `kubectl apply` commands.

Terraform remains the authoritative mutation path.

`kubectl` is used only for read-only deployment verification where permitted by the project-scoped RBAC.

The required sequence is:

```text
terraform init
terraform validate
terraform fmt -check
terraform plan -out=<saved-plan>
human approval
terraform apply <same-saved-plan>
```

The exact saved plan approved by the operator must be the plan applied.

Do not recompute deployment variables between approval and apply.

## 11. Terraform Target Separation

Use separate Terraform roots and separate HCP Terraform workspaces/states per deployment target.

Preferred long-term structure:

```text
infra/
  homelab/
    # existing homelab deployment
    # HCP workspace: omnivise-iot-k8s

  aws/
    # future EKS deployment
    # separate HCP workspace/state
```

Do not introduce unnecessary dynamic workspace-selection machinery merely to support multiple targets.

A target owns its own:

- Terraform root;
- HCP workspace/state;
- Kubernetes access method;
- deployment plan;
- approval;
- apply;
- verification.

This keeps the environments independent and easy to understand.

## 12. HCP Terraform Execution Model

The homelab deployment continues to use HCP Terraform with **Local Execution**.

Reason:

- the k3s API is LAN-only;
- Terraform must execute on the Jenkins host;
- HCP Terraform provides remote state and locking.

There must be no fallback to local Terraform state if HCP is unavailable.

Failure to access the authoritative remote state must fail the delivery.

## 13. Human Approval Boundary

A Terraform apply requires explicit human approval.

The operator must be able to see which release is being approved, including at least:

- deployment target;
- Git SHA;
- exact image references;
- saved-plan identity/path as appropriate.

After approval, Jenkins applies the exact saved plan.

The current accepted model allows registry publication to occur before Terraform approval, matching the proven HomeStreamLab pattern.

For the current homelab-only milestone this is acceptable.

Whether future GHCR publication should also happen before approval remains an AWS-delivery design decision. It must not complicate the Homelab Delivery implementation now.

## 14. Credentials and Security Model

Use the existing shared Jenkins platform credential pattern:

```text
local secret file
  -> Docker Compose secret
  -> Jenkins JCasC credential
  -> withCredentials
  -> smallest necessary pipeline scope
```

Rules:

- credentials are never stored in the repository;
- credentials are not exposed globally when per-operation binding is sufficient;
- credential-bearing shell blocks disable shell tracing;
- least-privilege credentials are used;
- no cluster-admin fallback is permitted;
- plan files containing sensitive Terraform values are not archived.

The existing OmniVise project-scoped k3s deployer identity must be used for
homelab delivery. That identity already exists on the cluster and was proven
during the controlled homelab deployment work.

The corresponding Jenkins Secret File credential does not yet exist in the shared
Jenkins platform. Creating and onboarding that credential — intended credential
id `k3s-omnivise-iot` — is part of the Homelab Delivery onboarding work. This
document does not claim the credential already exists in Jenkins.

## 15. AWS Authentication Constraint

Future AWS delivery must **not use GitHub Actions OIDC**.

Reason: the AWS account is shared by multiple users/projects, and the GitHub OIDC provider is an account-level resource whose ownership/management could conflict if another user or Terraform configuration attempts to manage the same provider.

The AWS delivery path will therefore use explicit scoped AWS credentials supplied through Jenkins.

The exact AWS credential design is future work.

## 16. AWS Registry Constraint

Future AWS delivery must **not use Amazon ECR**.

Images for the AWS EKS deployment will be published to GHCR.

This keeps the demo architecture simple and avoids unnecessary AWS-specific image storage.

## 17. Homelab Post-Deploy Verification

The OmniVise post-deploy verification should be stronger than the current HomeStreamLab pipeline because the required behavior has already been proven manually during the controlled homelab deployment.

The normal automated verification should remain bounded and non-destructive.

Expected checks include:

- workload readiness;
- exact running image SHA/ref verification;
- MongoDB replica set reports `rs0` PRIMARY;
- canonical HTTP endpoint returns success;
- bounded WebSocket/data-path smoke verifies fresh sensor traffic;
- deployment remains compatible with the namespace ResourceQuota.

Verification must respect the least-privilege deployer RBAC.

Where a check requires permissions intentionally not granted to the deployer, prefer an equivalent read-only mechanism rather than broadening RBAC without justification.

The `#40` manual proof that the MongoDB replica set reports `rs0` PRIMARY was
performed with the separate operator/admin inspection identity, not the
least-privilege Jenkins deployer. Automated delivery must **not** simply add
`exec`/`port-forward` permissions to the project-scoped deployer in order to
reproduce that check. It should instead use a deployer-safe read-only mechanism
if one is available, or an explicitly scoped operator verification step if one is
required. This document does not prescribe that implementation now and does not
broaden the deployer RBAC.

## 18. What Must NOT Be Automated in Normal Delivery

The controlled MongoDB Pod recreation used during the original homelab persistence proof must not become a standard Jenkins release step.

In particular, normal CD must not perform:

```text
kubectl delete pod mongodb-0
```

That operation was an acceptance/proof exercise for persistence and Change Stream recovery, not a routine deployment requirement.

Normal delivery smoke must be non-destructive.

## 19. Failure Semantics

The delivery pipeline must fail closed.

Examples:

- malformed Git SHA -> fail;
- homelab preflight failure -> fail;
- partial registry release set -> fail;
- ambiguous registry response -> fail;
- failed image publication verification -> fail;
- Terraform init/state failure -> fail;
- invalid Terraform configuration -> fail;
- failed saved plan creation -> fail;
- approval abort/timeout -> no apply;
- failed exact-plan apply -> fail;
- readiness timeout -> fail;
- live image mismatch -> fail;
- smoke-test failure -> fail.

Do not silently guess, repair partial registry state, switch credentials, use local Terraform state, or broaden permissions.

## 20. Timeout and Retry Philosophy

Follow the proven Jenkins platform model:

- no single global pipeline timeout that can race with a human approval window;
- bounded stage/operation timeouts;
- bounded readiness polling;
- bounded infrastructure preflight retries;
- no unbounded retry loops;
- no generic retry of mutation steps.

A failed mutation must be surfaced rather than blindly retried.

## 21. Cleanup

Saved Terraform plans may contain sensitive values.

They must:

- use restrictive filesystem permissions;
- not be committed;
- not be archived as Jenkins artifacts;
- be explicitly deleted;
- be followed by workspace cleanup.

Cleanup must run even when the pipeline fails or an approval is aborted.

## 22. Rollback Model

No automatic rollback is required for this milestone.

Terraform may partially apply before an error; the next operator-approved run should reconcile from authoritative HCP state.

Registry publication is write-once and is not automatically deleted.

Future `both` deployments are independent:

```text
homelab = PASS
aws     = FAIL
```

does not trigger an automatic homelab rollback.

This is intentional.

## 23. Relationship to the Proven Homelab Deployment

The Homelab Delivery milestone does not redesign the OmniVise runtime architecture.

Its purpose is to automate the already-proven controlled homelab deployment workflow.

Existing deployment decisions remain authoritative, including:

- Terraform-managed homelab workloads;
- MongoDB persistent replica-set topology;
- helper-container resource sizing;
- Traefik ingress;
- canonical homelab hostname;
- project-scoped Kubernetes RBAC;
- namespace ResourceQuota;
- exact-SHA application images;
- MongoDB Change Stream recovery behavior.

The delivery milestone must not reopen those implementation decisions unless a concrete automation blocker is discovered.

## 24. Relationship to HomeStreamLab

HomeStreamLab is the reference implementation for the shared Jenkins delivery pattern.

Patterns to reuse:

- static project onboarding in `local-jenkins-platform`;
- main-only multibranch pipeline;
- periodic/manual scan model;
- exact Git SHA release identity;
- build-once / reuse-existing-release behavior;
- fail-closed Registry V2 precheck;
- post-push digest verification;
- homelab preflight;
- Terraform Local Execution with HCP state;
- project-scoped kubeconfig;
- saved-plan approval;
- exact saved-plan apply;
- bounded readiness verification;
- per-operation credential binding;
- explicit plan/workspace cleanup.

HomeStreamLab-specific behavior must not be copied blindly, including:

- its two-image assumption;
- its SPA routing/build arguments;
- its PostgreSQL-specific variables;
- its exact RBAC shape;
- its exact workload names;
- its limited post-deploy smoke coverage.

OmniVise has its own three-image runtime, MongoDB replica set, WebSocket data path, and already-proven homelab verification requirements.

On Terraform workspaces specifically: OmniVise deliberately uses one literal HCP
Terraform workspace per deployment target. Homelab uses the existing
`omnivise-iot-k8s` workspace; future AWS uses a separate literal workspace/state.
Do not introduce dynamic workspace-selection machinery. The mistake to avoid is
assuming that one workspace covers every deployment target.

## 25. Milestone Boundaries

### Current milestone: Homelab Delivery

Implement:

```text
DEPLOY_TARGET=homelab
```

including:

- OmniVise GitHub Actions pull-request CI workflow (tests, lint/static validation, and build checks), if still absent;
- OmniVise onboarding into the shared Jenkins platform;
- Jenkins homelab delivery pipeline;
- exact-SHA build and local-registry publication;
- fail-closed publication contract;
- Terraform saved-plan workflow;
- human approval;
- exact-plan apply;
- bounded non-destructive OmniVise post-deploy smoke;
- cleanup and audit-friendly logging.

### Future milestone: AWS EKS Deployment

First prove the AWS infrastructure and deployment manually.

Expected direction:

- `infra/aws/`;
- EKS;
- GHCR images;
- explicit Jenkins-compatible AWS credential model;
- no GitHub OIDC;
- no ECR.

### Future milestone: Multi-Target Delivery

Extend the Jenkins pipeline with:

```text
DEPLOY_TARGET=aws
DEPLOY_TARGET=both
```

without rewriting the homelab path.

## 26. Final Accepted Architecture

```text
                    GitHub Actions CI
                           |
                        merge main
                           |
                           v
                        Jenkins
                           |
                    exact Git SHA
                           |
                    build images once
                           |
              +------------+------------+
              |                         |
              |                         |
        homelab target              AWS target
         current work                future
              |                         |
      local registry                  GHCR
              |                         |
      infra/homelab/                infra/aws/
              |                         |
    HCP Local Execution          HCP-backed state
              |                         |
       saved TF plan               saved TF plan
              |                         |
       human approval              human approval
              |                         |
       exact-plan apply            exact-plan apply
              |                         |
             k3s                       EKS
              |                         |
      non-destructive smoke      non-destructive smoke
```

Long-term operator choice:

```text
DEPLOY_TARGET=homelab
DEPLOY_TARGET=aws
DEPLOY_TARGET=both
```

`DEPLOY_TARGET` controls both publication and deployment.

There is no `PUSH_TARGET`.

There is no ECR.

There is no GitHub-to-AWS OIDC.

The architecture intentionally favors a small, understandable, portfolio-quality delivery system over unnecessary platform complexity.
