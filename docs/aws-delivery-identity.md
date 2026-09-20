# AWS Delivery Identity Contract

**Status:** Accepted, provisioned, and verified (issue #118); GHCR and shared
HCP Terraform delivery credentials rotated and documented (issue #137)
**Scope:** Jenkins AWS authentication/authorization and Jenkins/GHCR credential
contract for the future AWS EKS application delivery path.
**Relationship to other documents:** This document is the detailed reference for
[`docs/architecture/delivery-architecture.md`](architecture/delivery-architecture.md)
section 15 (AWS Authentication Constraint). That document remains authoritative
for the overall delivery pipeline shape; this document defines only the identity
and credential contract.

This document itself changes only `docs/**` and `README.md`; it performs no
AWS, GitHub, Jenkins, HCP Terraform, Kubernetes, or GHCR mutation. That is
distinct from the scope of issue #118 as a whole, which is now complete:

- **Repository implementation changes**: documentation only, under `docs/**`
  and `README.md`.
- **Controlled external/manual provisioning**: creating the AWS IAM
  principals, the IAM role and its policies/trust, the EKS access entry, and
  onboarding both Jenkins credentials was part of *completing* issue #118.
  This provisioning has been performed manually/externally (not via a
  repository change), and its read-only verification evidence (section 7) is
  recorded below as part of issue #118's Definition of Done.
- **Still out of scope, deferred to later issues**: implementing the Jenkins
  `aws` delivery-stage pipeline logic and publishing application images
  (issue #121 and later work). Ephemeral AWS demo bootstrap automation is
  tracked separately as its own future item (#128), not as part of the
  identity contract itself.

No separate tracking issue exists for the provisioning step described above;
it was tracked and completed as part of issue #118 itself, not as independent
work.

### Issue #137 scope

Issue #137 is a documentation-only follow-up. It rotated the two GHCR
credentials (`ghcr-omnivise-iot-publisher`, `ghcr-omnivise-iot-pull`) and the
shared HCP Terraform credential this project consumes (`hcp-terraform-cli`),
and extended this document to describe the pull credential and the HCP
Terraform credential's cross-repository lifecycle, neither of which was
previously covered here. It made no change to the AWS delivery identity
(section 2), the AWS authentication constraints (section 3), the
`infra/aws/` Terraform resources, any Jenkins job, or the existing documented
flow of the GHCR pull credential into HCP Terraform state through the
`infra/aws/` application root (`docs/aws-eks-application.md`) — that flow is
unchanged and out of scope here.

## 1. Why a dedicated identity is required

The existing operator/bootstrap AWS identity (`cli-access-gtoth`,
`AdminAssumeRole`) has `AdministratorAccess` and is used for manual, human-driven
provisioning of AWS resources such as `infra/aws-platform/`. It must never become
the steady-state Jenkins delivery identity: a compromised or misconfigured
Jenkins job with `AdministratorAccess` could affect any resource in the shared
AWS account, including resources belonging to other projects.

AdministratorAccess is permitted only for operator/bootstrap provisioning of the
dedicated delivery identity described below — never as a Jenkins runtime
credential.

## 2. AWS identity model

```text
Jenkins
  |
  | (long-lived access key, bootstrap-only)
  v
omnivise-iot-jenkins-bootstrap        (dedicated IAM user)
  | sts:AssumeRole only
  v
omnivise-iot-jenkins-delivery         (IAM role)
  |
  v
arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot
  (eks:DescribeCluster only)
  |
  v
EKS access entry -> AmazonEKSAdminPolicy, namespace-scoped
  namespace: omnivise-iot
```

### 2.1 Bootstrap principal: `omnivise-iot-jenkins-bootstrap`

- A dedicated IAM user created specifically for Jenkins, distinct from every
  human operator identity.
- Is **not** `cli-access-gtoth` and is **not** `AdminAssumeRole`.
- Does **not** carry `AdministratorAccess` or any broad managed policy.
- Has exactly one permission: `sts:AssumeRole` on the single resource
  `arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery`.
- The long-lived access key belonging to this user exists solely as the initial
  authentication bootstrap for Jenkins. It is not an authorization boundary by
  itself — the role it can assume is the boundary.

### 2.2 Delivery role: `omnivise-iot-jenkins-delivery`

- The only role the bootstrap principal is permitted to assume.
- Its trust policy admits only `omnivise-iot-jenkins-bootstrap` as a principal.
- Carries no generic EC2, IAM, EBS, ELB, ECR, or `AdministratorAccess`
  permissions.
- Currently approved permission boundary:

  | Action | Resource |
  | --- | --- |
  | `eks:DescribeCluster` | `arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot` |

  This is deliberately minimal for the current milestone. It authenticates the
  assumed role against the target EKS cluster (`aws eks update-kubeconfig`
  requires `DescribeCluster`) without granting any AWS-API-level cluster
  mutation capability. Kubernetes-level authorization is granted separately
  through the EKS access-entry model (section 2.3), not through IAM policy on
  this role.
- Additional AWS permissions required by future delivery work (for example,
  reading Terraform-managed outputs, or any AWS API calls the `infra/aws/`
  application root itself needs) must be added explicitly and reviewed against
  this same least-privilege standard — they are not implied by this contract.

### 2.3 Kubernetes authorization: EKS access entry

- The delivery role is granted access to the `omnivise-iot` EKS cluster through
  the [EKS access-entry
  model](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html),
  not a `~/.kube/config` static mapping and not `aws-auth` ConfigMap editing.
- Associated policy: `AmazonEKSAdminPolicy`.
- Access scope: **namespace**, scoped to `omnivise-iot` only.
- The role must **not** receive `AmazonEKSClusterAdminPolicy` or a
  cluster-scoped access association.

This mirrors the existing homelab pattern (`infra/modules/application/`, see
`infra/modules/application/main.tf`): the shared application module reads an
existing namespace via a `kubernetes_namespace_v1` data source and manages only
namespaced application resources — it does not create namespaces or manage
cluster-scoped platform resources. Namespace-scoped `AmazonEKSAdminPolicy` gives
Jenkins exactly the authority the application module needs and nothing more.
Platform and cluster-scoped capabilities (VPC, EKS cluster, node groups, the
existing `infra/aws-platform/aws_eks_access_entry.operator` cluster-admin
access entry — see `infra/aws-platform/access.tf` and `infra/aws-platform/iam.tf`)
remain outside the application delivery identity and continue to be owned by
the operator/bootstrap identity.

The `omnivise-iot` Namespace itself is one of those cluster-scoped resources.
Terraform ownership: `infra/aws-platform/` owns it (`namespace.tf`);
`infra/aws/` does not own it and only references it by its known name — this
is a Terraform-configuration fact, independent of any IAM identity. IAM
authorization is a separate, narrower fact: the namespace-scoped delivery role
described in this section is not authorized to create or delete the Namespace
either way, because its EKS access entry only grants `AmazonEKSAdminPolicy`
scoped to the `omnivise-iot` namespace, which governs namespaced objects
inside that namespace, not the Namespace object itself. The delivery role is
not a resource owner of anything in this architecture; ownership is a
Terraform-root property, not an IAM-role property. See
[AWS EKS Platform](./aws-eks-platform.md#application-namespace-capability).

## 3. Explicit AWS authentication constraints

The OmniVise AWS delivery path must **not** introduce:

- GitHub-to-AWS OIDC;
- an `aws_iam_openid_connect_provider` resource;
- a `token.actions.githubusercontent.com` trust dependency;
- `sts:AssumeRoleWithWebIdentity`;
- GitHub Actions as AWS delivery authority;
- Amazon ECR.

This constraint exists because the AWS account (`554422868760`) is shared
across multiple users/projects. A GitHub OIDC provider is an account-global
resource; if OmniVise's Terraform tried to own or reconfigure it, that would
conflict with any other project or user managing the same provider. Explicit,
scoped, long-lived-bootstrap-then-assume-role credentials avoid that shared
ownership problem entirely (delivery-architecture section 15).

GitHub Actions remains pull-request CI only. Jenkins remains the sole post-merge
delivery authority, exactly as for the homelab target.

## 4. GHCR credential contracts

Two separate GHCR credentials exist, with different purposes and different
scope requirements. They must not be conflated or substituted for each other.

### 4.1 Publisher credential: `ghcr-omnivise-iot-publisher`

| Property | Value |
| --- | --- |
| Jenkins credential ID | `ghcr-omnivise-iot-publisher` |
| GitHub/GHCR identity | `AldrionDev` |
| Credential type | GitHub Personal Access Token (classic) |
| Intended scope | `write:packages` |
| Observed scopes (current token) | `repo`, `write:packages` |
| Expiration | No expiration set |
| Explicitly not required | `delete:packages` |

**This credential is not minimally scoped.** Its currently observed scopes
are exactly `repo` and `write:packages`. During the issue #137 rotation, the
`repo` scope was observed alongside `write:packages` when the replacement PAT
was created through GitHub's classic-PAT UI; this is a same-rotation
observation about that one PAT creation, not a claim that GitHub universally
requires `repo` for classic package-scope tokens, and it is not an
intentional expansion of OmniVise's Jenkins permission boundary. Do not
describe this credential as minimally scoped in future documentation or
reviews; if a future rotation is able to create an equivalent token without
`repo`, it should adopt that, but no rotation is required solely to remove
`repo` today.

The PAT itself is created by the maintainer against their own `AldrionDev`
GitHub account. Once created, it is stored and onboarded outside Git through
the external `local-jenkins-platform` secret/JCasC mechanism (section 5),
exactly like the existing `k3s-omnivise-iot` and `hcp-terraform-cli`
credentials already bound in the `Jenkinsfile`.

This credential was provisioned and consumed by issue #118, initially only
for non-publishing GHCR authentication verification (section 7.3/7.4). Issue
#121 exercises the actual publication path with it:

- exact-SHA package existence/probe operations against GHCR;
- exact-SHA image push;
- post-push digest verification.

### 4.2 Pull credential: `ghcr-omnivise-iot-pull`

| Property | Value |
| --- | --- |
| Jenkins credential ID | `ghcr-omnivise-iot-pull` |
| GitHub/GHCR identity | `AldrionDev` |
| Credential type | GitHub Personal Access Token (classic) |
| Required scope | `read:packages` |
| Observed scopes (current token) | `read:packages` |
| Expiration | No expiration set |
| Explicitly not required | `write:packages`; `delete:packages`; `repo` |

This credential is minimally scoped at `read:packages`. It authenticates a
read-only GHCR identity and must never be granted `write:packages` — that
capability belongs exclusively to `ghcr-omnivise-iot-publisher` (section
4.3).

The pull credential is bound in the `Jenkinsfile`'s `infra/aws` plan stage as
`TF_VAR_ghcr_username` / `TF_VAR_ghcr_token`, feeding the `ghcr-pull`
Kubernetes image-pull Secret that `infra/aws/registry.tf` manages. Because
Terraform manages that Secret, the rendered credential material is persisted
in HCP Terraform state; this is an existing, already-documented design
exception (`docs/aws-eks-application.md`, "Private GHCR Image Pulls") and is
unchanged by issue #137.

### 4.3 Separation of trust domains

The AWS credential (`aws-omnivise-iot-bootstrap`), the GHCR publisher
credential (`ghcr-omnivise-iot-publisher`) and the GHCR pull credential
(`ghcr-omnivise-iot-pull`) are separate Jenkins credentials bound
independently. None grants any access to another's system, and the
write-capable publisher credential is never used for the Terraform-managed
pull path (section 4.2) or vice versa. A compromise or rotation of one has no
effect on the others' validity.

## 5. Secret provisioning contract

```text
maintainer/operator provisions AWS IAM identity + secret material
  -> Docker Compose / platform secret        (external local-jenkins-platform)
  -> Jenkins JCasC credential                (deterministic credential ID)
  -> narrowly scoped withCredentials binding (per pipeline stage/operation)
  -> operation
  -> credential unbound
```

This is the same pattern already documented in delivery-architecture section 14
and already used in the `Jenkinsfile` for `hcp-terraform-cli` and
`k3s-omnivise-iot` (`withCredentials([string(...)])` /
`withCredentials([file(...)])`, bound only around the stage that needs them).

The AWS IAM identity itself (the user, the role, its policies, and the EKS
access entry) is not part of this secret-flow diagram — it is AWS
infrastructure, not a secret, and is provisioned directly by the
maintainer/operator (section 2). Only the resulting long-lived access key is a
secret that flows through the chain above.

Rules that apply to the AWS credential and both GHCR credentials:

- None of these credentials' secret material is ever committed to Git.
- The AWS access key is never generated by Terraform and never written into HCP
  Terraform state — it is created directly against the
  `omnivise-iot-jenkins-bootstrap` IAM user outside Terraform. (The GHCR pull
  credential's own, separate, already-documented flow into HCP Terraform
  state is covered in section 4.2 and is not affected by this rule.)
- None of these credentials is printed in logs, console output, or archived
  artifacts.
- Credential-bearing shell blocks disable shell tracing (`set +x`), matching the
  existing convention at every `withCredentials` shell step in the `Jenkinsfile`.
- Each credential is bound with the smallest necessary pipeline scope and
  unbound immediately after the operation that needs it completes.

### 5.1 Jenkins credential IDs (deterministic)

| Credential ID | Type | Purpose |
| --- | --- | --- |
| `aws-omnivise-iot-bootstrap` | Jenkins username/password (username = AWS Access Key ID, password = AWS Secret Access Key) | Bootstrap authentication for `omnivise-iot-jenkins-bootstrap`, used only to call `sts:AssumeRole` |
| `ghcr-omnivise-iot-publisher` | Jenkins username/password (username = `AldrionDev`, password = GitHub PAT classic) | GHCR write authentication for `AldrionDev`; observed scopes `repo`, `write:packages` (section 4.1) |
| `ghcr-omnivise-iot-pull` | Jenkins username/password (username = `AldrionDev`, password = GitHub PAT classic) | GHCR read-only authentication for `AldrionDev`, `read:packages` only (section 4.2) |

All three IDs are stable, human-readable, and namespaced to this project,
consistent with the existing `hcp-terraform-cli` and `k3s-omnivise-iot` naming
convention.

### 5.2 Ownership of each provisioning step

| Step | Owner |
| --- | --- |
| `omnivise-iot-jenkins-bootstrap` IAM user creation | OmniVise maintainer/operator, using the approved operator/bootstrap AWS authority |
| `omnivise-iot-jenkins-delivery` IAM role, its policies, and its trust policy | OmniVise maintainer/operator |
| EKS access entry and namespace-scoped `AmazonEKSAdminPolicy` association | OmniVise maintainer/operator |
| AWS access key creation for `omnivise-iot-jenkins-bootstrap` | OmniVise maintainer/operator — never Terraform-managed, never committed to Git, never written into HCP Terraform state |
| External secret storage and Jenkins JCasC onboarding of `aws-omnivise-iot-bootstrap` | `local-jenkins-platform` |
| GitHub PAT (classic) creation for `AldrionDev` (publisher, pull) | OmniVise maintainer, using their own GitHub account |
| External secret storage and Jenkins JCasC onboarding of `ghcr-omnivise-iot-publisher` | `local-jenkins-platform` |
| External secret storage and Jenkins JCasC onboarding of `ghcr-omnivise-iot-pull` | `local-jenkins-platform` |

`local-jenkins-platform` owns only the external secret storage and Jenkins
credential (JCasC) onboarding step for both GHCR credentials — it does not
create, own, or manage the AWS IAM user, IAM role, EKS access entry, or
either GitHub PAT itself. Those are created directly by the OmniVise
maintainer/operator against AWS and GitHub respectively, before the resulting
secret material is handed to `local-jenkins-platform` for onboarding. This
repository documents the contract; it does not perform any of these
provisioning steps.

### 5.3 HCP Terraform credential (shared, cross-repository)

The `infra/aws` Terraform plan/apply steps in the `Jenkinsfile` also bind
`hcp-terraform-cli` (a Jenkins Secret Text credential) for
`TF_TOKEN_app_terraform_io`. Unlike the AWS and GHCR credentials above,
`hcp-terraform-cli` is not OmniVise-specific:

- it is owned, provisioned, and rotated entirely by `local-jenkins-platform`,
  as a single global-scope credential on the shared Jenkins controller — this
  repository consumes it but does not own or rotate it;
- known consumers of this same credential id include OmniVise IoT,
  HomeStreamLab, and HomeOps — rotating it is a platform-wide operation, not
  an OmniVise-scoped one;
- the token is deliberately long-lived but finite (current operational
  baseline: an expiration horizon of approximately two years); see
  `local-jenkins-platform`'s README, "HCP Terraform authentication" section,
  for the authoritative expiration/renewal baseline and rotation procedure.

This document does not restate that rotation procedure; it only records that
OmniVise IoT is a consumer and that the credential's lifecycle is owned
elsewhere.

## 6. Rotation and recovery

### 6.1 AWS bootstrap credential rotation

1. Create a second access key for the `omnivise-iot-jenkins-bootstrap` IAM user
   (AWS allows up to two active keys per user, enabling zero-downtime rotation).
2. Update the external Jenkins secret backing `aws-omnivise-iot-bootstrap` with
   the new key.
3. Verify the Jenkins credential binding and the resulting STS identity chain
   (`aws sts get-caller-identity`, then `aws sts assume-role` against
   `omnivise-iot-jenkins-delivery`) without printing any secret material.
4. Verify the assumed role can still reach the target (e.g.
   `aws eks describe-cluster --name omnivise-iot`).
5. Disable the previous access key (do not delete it yet).
6. Re-run delivery authentication verification (steps 3–4) with the previous
   key disabled to confirm the new key is sufficient on its own.
7. Only after that verification succeeds, delete the previous access key.

The previous working key must never be deleted before the replacement has been
verified end to end. Disabling before deleting gives a safe rollback point if
the new key turns out to be misconfigured.

### 6.2 GHCR publisher PAT rotation (`ghcr-omnivise-iot-publisher`)

1. Create a replacement GitHub PAT (classic) for `AldrionDev` intending
   exactly `write:packages`. If `repo` appears alongside it, as observed
   during the issue #137 rotation (section 4.1), that is not treated as a
   rotation defect and does not block completing rotation.
2. Replace the external Jenkins secret backing `ghcr-omnivise-iot-publisher`.
3. Recreate or reload Jenkins so the new secret is mounted and the credential
   is re-created from it.
4. Verify GHCR authentication/probe capability (e.g. an authenticated manifest
   HEAD request or `docker login`/`docker logout` against `ghcr.io`) without
   publishing an application image.
5. Only after that verification succeeds, revoke the previous PAT.

### 6.3 GHCR pull PAT rotation (`ghcr-omnivise-iot-pull`)

1. Create a replacement GitHub PAT (classic) for `AldrionDev` with exactly
   `read:packages` — no `write:packages`, `delete:packages`, or `repo`.
2. Replace the external Jenkins secret backing `ghcr-omnivise-iot-pull`.
3. Recreate or reload Jenkins so the new secret is mounted and the credential
   is re-created from it.
4. Verify GHCR authentication (e.g. `docker login`/`docker logout` against
   `ghcr.io`) without pulling or publishing an application image, and without
   running a Terraform plan/apply against `infra/aws` as part of this
   verification.
5. Only after that verification succeeds, revoke the previous PAT.

### 6.4 HCP Terraform credential rotation (cross-reference)

`hcp-terraform-cli` is rotated by `local-jenkins-platform`, not by this
repository (section 5.3). This repository's role in that rotation is limited
to independently verifying, after the platform rotates the token, that
`infra/aws` Terraform operations still authenticate successfully — it never
creates, updates, or revokes the token itself. See
`local-jenkins-platform`'s README, "Token rotation", for the authoritative
procedure, and note that rotation affects every Jenkins consumer of that
credential id, not only OmniVise IoT.

### 6.5 Recovery behavior for invalid/revoked credentials

If any of the AWS, GHCR, or HCP Terraform credentials described above is
invalid, expired, or revoked, the pipeline must fail closed:

- Delivery must not fall back to an operator/admin identity (`cli-access-gtoth`,
  `AdminAssumeRole`) or to any broader credential.
- Delivery must not silently skip the affected stage.
- The failure must be surfaced the same way any other fail-closed condition in
  delivery-architecture section 19 is surfaced — the run stops, and the
  operator restores a valid credential through the rotation procedure above.

## 7. Verification contract (read-only)

All verification below is read-only. No command in this section provisions,
mutates, or deletes any AWS, GitHub, Jenkins, HCP Terraform, Kubernetes, or GHCR
resource.

Verification was performed as part of completing issue #118, in this sequence:

1. The maintainer/operator provisioned the approved AWS IAM/EKS identity
   boundary (section 2): the `omnivise-iot-jenkins-bootstrap` user, the
   `omnivise-iot-jenkins-delivery` role and its policies/trust, and the EKS
   access entry.
2. Read-only AWS boundary verification (section 7.1) was performed against
   that identity boundary.
3. The bootstrap access key was created and onboarded into Jenkins as
   `aws-omnivise-iot-bootstrap` through `local-jenkins-platform`.
4. The GHCR PAT (classic) was created and onboarded into Jenkins as
   `ghcr-omnivise-iot-publisher` through `local-jenkins-platform`.
5. Jenkins credential binding/authentication verification (sections 7.2, 7.3)
   was performed without exposing secret material.
6. The verification evidence from steps 2 and 5 is recorded in section 7.4
   below as part of issue #118's completion (Verification Record).

### 7.1 AWS identity and role boundary

```bash
# Bootstrap principal has only sts:AssumeRole, scoped to one role.
aws iam list-attached-user-policies --user-name omnivise-iot-jenkins-bootstrap
aws iam list-user-policies --user-name omnivise-iot-jenkins-bootstrap
aws iam get-user-policy --user-name omnivise-iot-jenkins-bootstrap --policy-name <inline-policy-name>

# The delivery role's trust policy admits only the bootstrap principal.
aws iam get-role --role-name omnivise-iot-jenkins-delivery \
  --query 'Role.AssumeRolePolicyDocument'

# The delivery role does not carry AdministratorAccess or broad managed
# policies, and carries only the approved EKS DescribeCluster permission.
aws iam list-attached-role-policies --role-name omnivise-iot-jenkins-delivery
aws iam list-role-policies --role-name omnivise-iot-jenkins-delivery
aws iam get-role-policy --role-name omnivise-iot-jenkins-delivery --policy-name <inline-policy-name>

# EKS access entry for the delivery role is namespace-scoped
# AmazonEKSAdminPolicy, not cluster-scoped AmazonEKSClusterAdminPolicy.
aws eks list-associated-access-policies \
  --cluster-name omnivise-iot \
  --principal-arn arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery

# No GitHub OIDC provider dependency exists in this design.
aws iam list-open-id-connect-providers
```

None of these commands print secret material; they only read policy documents
and metadata.

### 7.2 Jenkins credential binding

- Confirm the credential IDs `aws-omnivise-iot-bootstrap`,
  `ghcr-omnivise-iot-publisher`, and `ghcr-omnivise-iot-pull` exist in the
  Jenkins credential store after external provisioning (Jenkins credentials
  UI or `jenkins-cli list-credentials`, which lists IDs/types, not secret
  values).
- Confirm each credential can be bound in a scratch/test pipeline step using
  `withCredentials`, and that the step's log output contains no secret value
  (shell tracing disabled, no `echo`/`printf` of the bound variable).

### 7.3 GHCR authentication/probe

The baseline issue #118 GHCR verification proves only that the credential
authenticates — it must not depend on an existing OmniVise application image
or tag, because issue #121 owns initial application image publication and no
such image is guaranteed to exist yet.

```bash
# Authenticate to GHCR and immediately log out. No image is pulled, pushed,
# or probed. Shell tracing is disabled so the token is never echoed, and a
# temporary Docker config keeps the credential out of the default config.
set +x
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u AldrionDev --password-stdin
docker logout ghcr.io
rm -rf "$DOCKER_CONFIG"
```

This confirms:

- the PAT (classic) authenticates successfully to `ghcr.io`;
- no application image is pushed;
- no secret value is printed.

It does not, and is not required to, prove that a push would succeed — `docker
login` exercises authentication only, not the `write:packages` push path
itself. Issue #121 will exercise the actual push path when it publishes the
first exact-SHA image.

If an existing GHCR package already happens to exist at verification time, an
authenticated probe against it (`docker manifest inspect
ghcr.io/aldriondev/<existing-image>:<existing-tag>`) may additionally be
recorded as optional supplementary evidence, but it is not required for issue
#118 completion.

The same `docker login`/`docker logout` pattern, substituting the
`ghcr-omnivise-iot-pull` credential and its own scratch `DOCKER_CONFIG`,
verifies the pull credential's authentication without pulling any image
(issue #137, section 7.5).

### 7.4 Verification evidence (issue #118, recorded)

The provisioning and verification sequence in this section has been
completed. The following read-only checks were run against the live AWS
account and the shared Jenkins platform, with no secret material printed and
no unapproved mutation performed.

**AWS identity boundary:**

- Bootstrap caller identity resolves to
  `arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap`.
- A direct `eks:DescribeCluster` call from the bootstrap principal fails (it
  holds no EKS permission itself).
- A bootstrap attempt to assume the operator/bootstrap `AdminAssumeRole` role
  fails (the bootstrap principal cannot escalate to admin).
- The bootstrap principal successfully assumes
  `omnivise-iot-jenkins-delivery`.
- The resulting assumed-role caller identity resolves to
  `arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/omnivise-118-verification`.
- The assumed delivery role's `eks:DescribeCluster` on `omnivise-iot`
  succeeds.
- The assumed delivery role's `eks:ListClusters` fails (no broader EKS
  permission than the single approved resource).
- The assumed delivery role's `iam:ListUsers` fails (no IAM read/write
  permission of any kind).
- The target cluster (`omnivise-iot`) is confirmed `ACTIVE`, Kubernetes
  version `1.36`.

**Jenkins credential onboarding (`local-jenkins-platform`, merged to
`main`):**

- `aws-omnivise-iot-bootstrap` (Jenkins username/password credential;
  username bound to the AWS Access Key ID, password bound to the AWS Secret
  Access Key) and `ghcr-omnivise-iot-publisher` (Jenkins username/password
  credential; username `AldrionDev`, password the GHCR PAT) are declaratively
  provisioned via JCasC, sourced from local gitignored `0600` secret files
  through a Docker Compose secret — no secret material is committed.
- The manual-only Jenkins job `platform/verify-delivery-capabilities`
  completed `Finished: SUCCESS`, confirming:
  - `aws-omnivise-iot-bootstrap` exists with non-empty Access Key ID and
    Secret Access Key bindings, neither printed;
  - `ghcr-omnivise-iot-publisher` exists with a non-empty PAT binding, not
    printed;
  - an authenticated `docker login ghcr.io` using that credential succeeds;
  - no application image is published;
  - the temporary Docker auth config used for the login is cleaned up
    afterward.

This evidence satisfies the section 7 verification contract and issue #118's
Definition of Done. It is reproducible by re-running the same read-only
commands and the same Jenkins job against the current environment.

### 7.5 Verification evidence (issue #137, recorded)

Issue #137 rotated both GHCR credentials and the shared HCP Terraform
credential and re-ran the same class of read-only checks as section 7.4
against the rotated material: for each credential, the Jenkins container's
bound secret was confirmed to match the new host secret, and an
authenticated, non-mutating probe against the target system succeeded
(`docker login`/`docker logout` against `ghcr.io` for each GHCR credential,
publishing or pulling no image; the manual-only
`platform/verify-delivery-capabilities` Jenkins job for `hcp-terraform-cli`,
completing `Finished: SUCCESS` with its HCP Terraform authentication check
passing). No secret material was printed. Each previous credential was
revoked only after its replacement's verification succeeded (GHCR scopes:
section 4.1, section 4.2; HCP Terraform token lifecycle: section 5.3).

This evidence satisfies issue #137's Definition of Done for credential
rotation and Jenkins-side verification. It supplements, and does not
replace, the issue #118 evidence recorded in section 7.4.

## 8. Acceptance criteria cross-reference

| Issue #118 acceptance criterion | Where addressed | Status |
| --- | --- | --- |
| Dedicated Jenkins AWS delivery identity contract exists | Section 2 | Satisfied |
| Jenkins steady-state AWS delivery does not use AdministratorAccess | Section 1, Section 2.2 | Satisfied |
| The AWS credential can assume only the intended OmniVise delivery role | Section 2.1, Section 7.4 | Satisfied |
| Required AWS permissions are documented and scoped | Section 2.2, Section 2.3 | Satisfied |
| GHCR credential contract exists for exact-SHA push/probe | Section 4 | Satisfied (contract only; push logic is issue #121) |
| Jenkins credential IDs are deterministic and documented | Section 5.1 | Satisfied |
| Secret values remain outside Git | Section 5 | Satisfied |
| Credential binding verification does not print secret values | Section 5, Section 7.2, Section 7.4 | Satisfied |
| Rotation/recovery procedure is documented | Section 6 | Satisfied |
| No ECR or GitHub-to-AWS OIDC dependency is introduced | Section 3 | Satisfied |
| AWS identity boundary and Jenkins credential onboarding are provisioned and verified | Section 7.4 | Satisfied |

## 9. What was done to complete issue #118

This documentation change (`docs/**`, `README.md`) does not itself create the
`omnivise-iot-jenkins-bootstrap` IAM user, the `omnivise-iot-jenkins-delivery`
role, the EKS access entry, or either Jenkins credential, and it does not run
any command in section 7 against a live account. Those actions are, and
remain, manual/external actions performed directly against AWS, GitHub, and
Jenkins, not repository changes.

Those provisioning and verification steps have now been performed by the
maintainer/operator, following the sequence in section 7 and gated on the
maintainer's approval of this contract. The resulting evidence is recorded in
section 7.4. This document reflects the completed state.

Genuinely deferred to later issues (not part of #118):

- implementing the Jenkins `aws` delivery-stage pipeline logic and publishing
  application images (issue #121);
- ephemeral AWS demo bootstrap automation (issue #128).

## 10. What was done to complete issue #137

This documentation change (`docs/aws-delivery-identity.md` only) does not
itself rotate any credential and does not run any command in section 7
against a live account or the shared Jenkins platform. The credential
rotation itself was manual/external work against GitHub (both PATs) and
against HCP Terraform (the `local-jenkins-platform`-owned team token), not a
repository change in this project.

What this document newly records, that was not covered before issue #137:

- the previously undocumented `ghcr-omnivise-iot-pull` credential — its
  scope, ownership, rotation procedure, and its existing (unchanged) role in
  the `infra/aws` Terraform/HCP state flow (section 4.2);
- the corrected framing of `ghcr-omnivise-iot-publisher` as not minimally
  scoped, with the `repo` scope attributed to what was observed in GitHub's
  classic-PAT UI during this rotation, not a universal GitHub requirement or
  an intentional permission expansion (section 4.1);
- the `hcp-terraform-cli` credential's shared, cross-repository ownership and
  lifecycle, cross-referenced to `local-jenkins-platform` rather than
  duplicated (section 5.3, section 6.4);
- Jenkins-side verification evidence for the rotated publisher, pull, and
  HCP Terraform credentials (section 7.5).

This document made no change to the AWS delivery identity (section 2), the
AWS authentication constraints (section 3), any `infra/**` Terraform
resource, or any Jenkins job definition. Issue #121's GHCR publication path
and issue #128's ephemeral AWS demo bootstrap automation remain deferred, as
recorded in section 9, and are unaffected by issue #137.
