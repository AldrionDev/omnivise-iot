# AWS Delivery Identity Contract

**Status:** Accepted, provisioned, and verified (issue #118)
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

## 4. GHCR credential contract

| Property | Value |
| --- | --- |
| Jenkins credential ID | `ghcr-omnivise-iot-publisher` |
| GitHub/GHCR identity | `AldrionDev` |
| Credential type | GitHub Personal Access Token (classic) |
| Required scope | `write:packages` |
| Explicitly not required | `delete:packages`; broad repository permissions |

The PAT itself is created by the maintainer against their own `AldrionDev`
GitHub account. Once created, it is stored and onboarded outside Git through
the external `local-jenkins-platform` secret/JCasC mechanism (section 5),
exactly like the existing `k3s-omnivise-iot` and `hcp-terraform-cli`
credentials already bound in the `Jenkinsfile`.

This credential is provisioned and consumed by issue #118, but only for
non-publishing GHCR authentication verification (section 7.3/7.4). Issue #118
must not publish any application image. Issue #121 owns the actual
publication path:

- exact-SHA package existence/probe operations against GHCR;
- exact-SHA image push;
- post-push digest verification.

### 4.1 Separation of trust domains

The AWS credential (`aws-omnivise-iot-bootstrap`) and the GHCR credential
(`ghcr-omnivise-iot-publisher`) are separate Jenkins credentials bound
independently. Neither grants any access to the other's system. A compromise or
rotation of one has no effect on the other's validity.

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

Rules that apply to both the AWS and GHCR credentials:

- Neither credential's secret material is ever committed to Git.
- The AWS access key is never generated by Terraform and never written into HCP
  Terraform state — it is created directly against the
  `omnivise-iot-jenkins-bootstrap` IAM user outside Terraform.
- Neither credential is printed in logs, console output, or archived artifacts.
- Credential-bearing shell blocks disable shell tracing (`set +x`), matching the
  existing convention at every `withCredentials` shell step in the `Jenkinsfile`.
- Each credential is bound with the smallest necessary pipeline scope and
  unbound immediately after the operation that needs it completes.

### 5.1 Jenkins credential IDs (deterministic)

| Credential ID | Type | Purpose |
| --- | --- | --- |
| `aws-omnivise-iot-bootstrap` | Jenkins username/password (username = AWS Access Key ID, password = AWS Secret Access Key) | Bootstrap authentication for `omnivise-iot-jenkins-bootstrap`, used only to call `sts:AssumeRole` |
| `ghcr-omnivise-iot-publisher` | Jenkins username/password (username = `AldrionDev`, password = GitHub PAT classic) | GHCR authentication for `AldrionDev`, `write:packages` |

Both IDs are stable, human-readable, and namespaced to this project, consistent
with the existing `hcp-terraform-cli` and `k3s-omnivise-iot` naming convention.

### 5.2 Ownership of each provisioning step

| Step | Owner |
| --- | --- |
| `omnivise-iot-jenkins-bootstrap` IAM user creation | OmniVise maintainer/operator, using the approved operator/bootstrap AWS authority |
| `omnivise-iot-jenkins-delivery` IAM role, its policies, and its trust policy | OmniVise maintainer/operator |
| EKS access entry and namespace-scoped `AmazonEKSAdminPolicy` association | OmniVise maintainer/operator |
| AWS access key creation for `omnivise-iot-jenkins-bootstrap` | OmniVise maintainer/operator — never Terraform-managed, never committed to Git, never written into HCP Terraform state |
| External secret storage and Jenkins JCasC onboarding of `aws-omnivise-iot-bootstrap` | `local-jenkins-platform` |
| GitHub PAT (classic) creation for `AldrionDev` | OmniVise maintainer, using their own GitHub account |
| External secret storage and Jenkins JCasC onboarding of `ghcr-omnivise-iot-publisher` | `local-jenkins-platform` |

`local-jenkins-platform` owns only the external secret storage and Jenkins
credential (JCasC) onboarding step for both credentials — it does not create,
own, or manage the AWS IAM user, IAM role, EKS access entry, or the GitHub PAT
itself. Those are created directly by the OmniVise maintainer/operator against
AWS and GitHub respectively, before the resulting secret material is handed to
`local-jenkins-platform` for onboarding. This repository documents the
contract; it does not perform any of these provisioning steps.

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

### 6.2 GHCR PAT rotation

1. Create a replacement GitHub PAT (classic) for `AldrionDev` with exactly
   `write:packages`.
2. Replace the external Jenkins secret backing `ghcr-omnivise-iot-publisher`.
3. Verify GHCR authentication/probe capability (e.g. an authenticated manifest
   HEAD request against an existing tag) without publishing an application
   image.
4. Revoke the previous PAT only after that verification succeeds.

### 6.3 Recovery behavior for invalid/revoked credentials

If either credential is invalid, expired, or revoked, the pipeline must fail
closed:

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

- Confirm the credential IDs `aws-omnivise-iot-bootstrap` and
  `ghcr-omnivise-iot-publisher` exist in the Jenkins credential store after
  external provisioning (Jenkins credentials UI or `jenkins-cli
  list-credentials`, which lists IDs/types, not secret values).
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
