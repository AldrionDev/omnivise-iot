# AWS Demo Runbook

Operator runbook for the OmniVise IoT AWS demo lifecycle, from a torn-down
`DOWN-CLEAN` state to a working demo and back to `DOWN-CLEAN`.

Related documents:

- [AWS EKS Platform](./aws-eks-platform.md) — `infra/aws-platform/`
- [AWS EKS Application Root](./aws-eks-application.md) — `infra/aws/`
- [AWS Delivery Identity Contract](./aws-delivery-identity.md) — Jenkins
  credentials, GHCR/HCP credential lifecycle (issue #137)
- `local-jenkins-platform` repository `README.md` — Compose secrets, JCasC and
  controlled restart

## 1. Purpose and Scope

| Concern | Authority |
| --- | --- |
| Pull-request CI | GitHub Actions (`.github/workflows/ci.yml`) |
| Post-merge build, publication and deployment | Jenkins (`projects/omnivise-iot`) |
| AWS platform and application mutation | Terraform saved plans (`infra/aws-platform/`, `infra/aws/`) |
| Lifecycle state and bootstrap access key | `scripts/aws-demo.sh` |
| Jenkins restart | `local-jenkins-platform` (operator-run) |

`scripts/aws-demo.sh` never runs Terraform, Jenkins or Compose. Its only
persistent mutations are `iam:CreateAccessKey` / `iam:DeleteAccessKey` on
`omnivise-iot-jenkins-bootstrap` and in-place writes of the two existing
Jenkins secret files.

A release is identified by one exact 40-character lowercase Git commit SHA;
backend, frontend and simulator images must all carry that same tag.

## 2. Preconditions

| Item | Value |
| --- | --- |
| AWS account | `554422868760` |
| Region | `eu-north-1` (every regional call is pinned) |
| Operator identity | `arn:aws:iam::554422868760:role/AdminAssumeRole` (EKS cluster-admin access entry); in this environment `AWS_PROFILE=omnivise-admin` |
| EKS cluster / namespace | `omnivise-iot` / `omnivise-iot` |
| HCP Terraform workspaces | `omnivise-iot-aws-platform` (platform state), `omnivise-iot-aws-app` (application state), both Local Execution, organization `gabor-toth-personalprojects` |

The script accepts only an AdminAssumeRole session: the `sts:GetCallerIdentity`
ARN must be exactly
`arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/<session-name>`. Any
other IAM user, role or session, the account root and the Jenkins bootstrap
user or delivery role are refused (exit 3).

`infra/aws/platform.tf` reads the platform outputs (`aws_region`,
`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`) through
`terraform_remote_state` (`backend = "remote"`, workspace
`omnivise-iot-aws-platform`). HCP workspace remote-state sharing is not
configured (`global-remote-state` is `false`, no remote-state consumers; verified
2026-09-21) and is not needed: with Local Execution the read uses the executing
HCP credential (operator `terraform login` token or the Jenkins HCP token), which
must be allowed to read the platform workspace state. Enabling sharing only
becomes necessary if the application workspace moves to remote execution.

Required tools: `aws` (CLI v2), `jq`, `mktemp`, `stat`, `realpath`, `flock`,
`date`, `id`, `rm`, `docker`, `kubectl`, `terraform`.

AWS CLI safety (checked before any classification or mutation; violation →
exit 3):

- `aws configure get cli_history` must not return `enabled`;
- no `AWS_ENDPOINT_URL` / `AWS_ENDPOINT_URL_*` variables;
- shell tracing (`set -x`) must be off.

### Local Jenkins platform

| Setting | Default |
| --- | --- |
| `OMNIVISE_JENKINS_PLATFORM_DIR` | `../local-jenkins-platform`, resolved relative to this repository's root (the sibling checkout) |
| `OMNIVISE_JENKINS_CONTAINER` | `local-jenkins-platform-jenkins-1` (Compose project `local-jenkins-platform`, service `jenkins`) |

The secret filenames are fixed and not configurable:

```text
<platform-dir>/secrets/omnivise_iot_aws_access_key_id
<platform-dir>/secrets/omnivise_iot_aws_secret_access_key
```

`local-jenkins-platform` mounts them as Compose secrets
(`/run/secrets/omnivise_iot_aws_access_key_id`,
`/run/secrets/omnivise_iot_aws_secret_access_key`) and JCasC turns them into the
Jenkins credential `aws-omnivise-iot-bootstrap`.

Both files must already exist and be regular, non-symlink files owned by the
operator with mode `0600`. The script writes them in place (preserving the
bind-mounted inode) and never creates, deletes or empties them. Missing or
wrongly mounted files are fixed in `local-jenkins-platform`, not by this tool.

## 3. Lifecycle States

| State | Meaning |
| --- | --- |
| `DOWN-CLEAN` | cluster absent and no project-owned AWS/IAM leftovers |
| `DOWN-DIRTY` | cluster absent but at least one project-owned leftover exists |
| `UP-NO-CREDENTIAL` | cluster `ACTIVE`, identity/access boundary valid, 0 bootstrap keys |
| `UP-RESTART-REQUIRED` | credential chain valid, Jenkins not (freshly) running |
| `READY` | credential chain, authorization boundary, mount identity and Jenkins freshness all pass |
| `VIOLATION` | transitional/failed cluster, or any broken/ambiguous invariant while the platform exists |

There is no other state. Every `STATE:` line is followed by `NEXT:` guidance.

| Exit | `status` | `issue-credential` / `revoke-credential` |
| --- | --- | --- |
| 0 | `READY` or `DOWN-CLEAN` | success or idempotent no-op |
| 1 | other expected lifecycle state | mutation done/retained but not converged or not ready yet |
| 2 | `VIOLATION` | invariant violation, ambiguity or mismatch |
| 3 | usage, environment or unexpected failure (no `STATE:` line) | usage, environment, lock or unexpected failure |

Mutator outputs that cannot prove a lifecycle state print only `DETAIL:` and
`NEXT:` (for example an idempotent issue no-op or a non-converged revoke).

## 4. Status

```bash
AWS_PROFILE=omnivise-admin bash scripts/aws-demo.sh status
```

`status` is read-only. It:

1. runs the security preflight and verifies the operator account/identity;
2. classifies cluster presence (only EKS `ResourceNotFoundException` means
   absent); when absent it scans for leftovers (VPC, subnets, Internet Gateway,
   route tables, EBS volumes, ELBv2 load balancers, bootstrap user, delivery and
   platform IAM roles, the ALB controller policy);
3. when present, requires cluster `ACTIVE` and the exact IAM/EKS identity
   boundary (exact inline policy documents and trust, no managed policies,
   groups or permissions boundary, namespace-scoped `AmazonEKSAdminPolicy`
   access entry, no bootstrap access entry);
4. with exactly one matching active key, validates the local secret files and
   the Jenkins mount sources (canonical path and device/inode);
5. runs the runtime chain with the bootstrap credential, isolated from ambient
   AWS configuration: exact bootstrap caller, denied direct `DescribeCluster`,
   denied `AdminAssumeRole`, assume the delivery role, exact delivery caller,
   allowed target `DescribeCluster`, denied `ListClusters` / `iam:ListUsers`;
6. checks Kubernetes authorization with a temporary kubeconfig and cache below
   a private temp directory (removed on exit/INT/TERM); kubectl authenticates
   through the exec plugin `aws eks get-token --region eu-north-1
   --cluster-name omnivise-iot` with the delivery session. Required answers:
   create deployments in `omnivise-iot` = `yes`; create namespaces, get
   kube-system secrets, create clusterrolebindings = `no`;
7. `READY` requires Jenkins `State.StartedAt` strictly later than
   `max(mtime, ctime)` of both secret files (nanosecond precision; equality or
   a parse failure is not fresh).

Normal progression:

```text
DOWN-CLEAN → (platform apply) → UP-NO-CREDENTIAL → (issue-credential)
  → UP-RESTART-REQUIRED → (Jenkins restart) → READY
READY → (revoke-credential) → UP-NO-CREDENTIAL → (app + platform destroy) → DOWN-CLEAN
```

## 5. Platform Bring-Up

```bash
AWS_PROFILE=omnivise-admin bash scripts/aws-demo.sh status
# expect STATE: DOWN-CLEAN, exit 0

cd infra/aws-platform
export AWS_PROFILE=omnivise-admin

terraform init
terraform validate
terraform fmt -check -recursive
terraform test
terraform plan -out=tfplan
terraform show tfplan
# human review and approval of exactly this saved plan
terraform apply tfplan
```

- Apply only the reviewed saved plan; never re-plan between approval and apply.
- Saved plans are local artifacts, may contain sensitive values and must not be
  committed (`tfplan*` is gitignored). Delete them after use.
- Verify with [AWS EKS Platform — Post-Apply Verification](./aws-eks-platform.md#post-apply-verification)
  and a convergence plan that reports `No changes`.

The platform graph orders Kubernetes/Helm resources after operator access and
the node group after public networking (see
[Known Destroy-Ordering Constraints](./aws-eks-platform.md#known-destroy-ordering-constraints)):

- `kubernetes_namespace_v1.application`, `kubernetes_storage_class_v1.gp3` and
  `helm_release.aws_load_balancer_controller` depend on
  `aws_eks_access_policy_association.operator_cluster_admin`;
- `aws_eks_node_group.this` depends on `aws_route.public_internet` and
  `aws_route_table_association.public`.

On a fresh state a single saved-plan apply and a single saved-plan destroy
therefore follow the correct order.

Afterwards `status` should report `UP-NO-CREDENTIAL` (exit 1).

## 6. Issue the Bootstrap Credential

```bash
AWS_PROFILE=omnivise-admin bash scripts/aws-demo.sh issue-credential
```

Before `create-access-key` is called the script verifies, under an exclusive
lock on the access-key ID file: cluster `ACTIVE`, the exact identity/access
boundary, 0 bootstrap keys, both secret files valid, the Jenkins container
exists and is running, and its mount sources match the two files.

- Exactly one key is created; a second key is never created. With an existing
  matching active key the command is an idempotent no-op (exit 0, `DETAIL`/`NEXT`
  only); any other existing-key state stops with `VIOLATION`.
- The create response is validated in memory. The secret is written first, the
  key ID second, both in place.
- A malformed response, a failed local write, a failed or malformed
  post-create `list-access-keys` verification, or an unexpected operational
  failure of the post-create AWS or Kubernetes runtime verification is a
  `VIOLATION` (exit 2) that keeps the written files and shows only the masked
  key suffix and the recovery command
  (`revoke-credential --key-id <suffix>`, then `issue-credential`). There is no
  automatic rollback.
- The key list and the runtime chain are re-checked with bounded retries; only
  `InvalidClientTokenId` from the new key is treated as IAM propagation.
  Exhausted propagation exits 1 with `NEXT: rerun scripts/aws-demo.sh status`.
  A runtime authorization `VIOLATION` is reported once, unchanged.

Success normally prints `STATE: UP-RESTART-REQUIRED` (exit 1).

## 7. Controlled Jenkins Restart

`aws-demo.sh` never restarts Jenkins. From the `local-jenkins-platform`
checkout:

```bash
cd ../local-jenkins-platform
docker compose restart jenkins
```

Compose remounts the secrets and JCasC re-creates `aws-omnivise-iot-bootstrap`
with the new material. A JCasC reload alone does not change `StartedAt` and does
not satisfy the freshness check.

Then run `status` again; the expected result is `STATE: READY` (exit 0).

## 8. Jenkins AWS Delivery

- Jenkins binds `aws-omnivise-iot-bootstrap`; the bootstrap user may only assume
  `omnivise-iot-jenkins-delivery`, whose Kubernetes access is namespace-scoped
  to `omnivise-iot` ([AWS Delivery Identity Contract](./aws-delivery-identity.md)).
- `platform/verify-delivery-capabilities` verifies the delivery identity
  read-only.
- Deliver by running `projects/omnivise-iot` (branch `main`) with
  `DEPLOY_TARGET=aws`. Jenkins publishes (or reuses) the exact-SHA GHCR release
  set and applies `infra/aws` with a reviewed saved plan; the post-deploy smoke
  checks are part of that run. Record the build number and whether images were
  built or reused.

`READY` proves the local credential chain; the Jenkins run is the end-to-end
proof that Jenkins consumed the credential.

## 9. Application Deployment (Operator Path)

When the application is applied by the operator instead of Jenkins
([AWS EKS Application Root — Apply Workflow](./aws-eks-application.md#apply-workflow)):

```bash
cd infra/aws
export AWS_PROFILE=omnivise-admin
# TF_VAR_ghcr_username / TF_VAR_ghcr_token must already be exported from a
# protected source; never echo them or pass them on the command line.
: "${TF_VAR_ghcr_username:?}" "${TF_VAR_ghcr_token:?}"

SHA=<40-character lowercase commit SHA>
terraform init
terraform validate
terraform test
terraform plan -out=tfplan \
  -var "backend_image_ref=ghcr.io/aldriondev/omnivise-iot-backend:${SHA}" \
  -var "frontend_image_ref=ghcr.io/aldriondev/omnivise-iot-frontend:${SHA}" \
  -var "simulator_image_ref=ghcr.io/aldriondev/omnivise-iot-simulator:${SHA}"
terraform show tfplan
# human review and approval
terraform apply tfplan
rm -f tfplan
```

All three images must exist for the same SHA (see
[GHCR release-set verification](./ghcr-release-set-verification.md)). The saved
application plan contains the GHCR pull token (the `ghcr-pull` Secret); delete
it right after apply and never commit it.

## 10. Live Verification

Use a temporary kubeconfig so `~/.kube/config` is never modified:

```bash
export KUBECONFIG="$(mktemp)"
aws eks update-kubeconfig --region eu-north-1 --name omnivise-iot --kubeconfig "$KUBECONFIG"
kubectl -n omnivise-iot get pods,pvc,ingress
kubectl -n omnivise-iot get sts mongodb \
  -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}{"\n"}'
# ... checks ...
rm -f "$KUBECONFIG"
```

- Application pods are `Running` / bootstrap Jobs `Completed`.
- PVC `data-mongodb-0` is `Bound` to an `ebs.csi.aws.com` PV.
- The MongoDB StatefulSet reports
  `{"whenDeleted":"Delete","whenScaled":"Retain"}` (read-only acceptance
  evidence that application teardown will garbage-collect the PVC, §12).
- The `frontend` Ingress has an ALB hostname (`terraform output
  frontend_ingress_hostname`); UI/API/WebSocket checks per the application doc.

Leftover attribution used by the `DOWN` scan (validated live, see §17):

- EBS: `ebs.csi.aws.com/cluster-name=omnivise-iot`, set by the EBS CSI driver.
  CSI-created volumes do not carry the Terraform `default_tags`
  (`Project`/`Environment`/`ManagedBy`).
- ELBv2: `elbv2.k8s.aws/cluster=omnivise-iot`, set by the AWS Load Balancer
  Controller. `ingress.k8s.aws/stack` is not required, so load balancers of any
  Ingress or Service in this cluster count. Load balancers and target groups
  tagged for another cluster are not OmniVise leftovers.

## 11. Revoke the Credential

Default revoke:

```bash
AWS_PROFILE=omnivise-admin bash scripts/aws-demo.sh revoke-credential
```

Deletes the key only when exactly one **Active** key exists, it matches the local
access-key ID file, and the full identity/access boundary is valid. Zero keys is
an idempotent no-op (`STATE: UP-NO-CREDENTIAL`, exit 0). Secret files are never
deleted or emptied.

Explicit recovery (recovery only):

```bash
AWS_PROFILE=omnivise-admin bash scripts/aws-demo.sh revoke-credential --key-id <full-key-id-or-unique-suffix>
```

- Selector: a full access-key ID or a unique suffix of at least 4 characters
  (`[A-Z0-9]`). No match, ambiguity or invalid shape → exit 3; candidate IDs are
  never printed.
- With the cluster present (any status) it requires the exact account, the exact
  bootstrap IAM user name/ARN and a readable key list, but not a healthy
  delivery role, trust, EKS access entry or Kubernetes authorization.
- With the cluster absent it runs the `DOWN` recovery path (a missing bootstrap
  user delegates to the full leftover scan).
- It deletes exactly the resolved key, changes no other IAM/EKS state and prints
  no lifecycle state it cannot prove (`NEXT: rerun scripts/aws-demo.sh status`).
- Delete failures report only the AWS error code and `****<last4>`.

After revoke, a Jenkins `DEPLOY_TARGET=aws` run must fail closed at bootstrap
authentication.

## 12. Application Teardown

Always destroy the application before the platform:

```bash
cd infra/aws
export AWS_PROFILE=omnivise-admin
SHA=<40-character lowercase commit SHA>
# Placeholder, non-secret values are sufficient for destroy.
TF_VAR_ghcr_username=placeholder TF_VAR_ghcr_token=placeholder \
terraform plan -destroy -out=tfplan \
  -var "backend_image_ref=ghcr.io/aldriondev/omnivise-iot-backend:${SHA}" \
  -var "frontend_image_ref=ghcr.io/aldriondev/omnivise-iot-frontend:${SHA}" \
  -var "simulator_image_ref=ghcr.io/aldriondev/omnivise-iot-simulator:${SHA}"
terraform show tfplan
# human review and approval
terraform apply tfplan
terraform state list          # expect no output
```

The AWS root sets the MongoDB StatefulSet
`persistentVolumeClaimRetentionPolicy.whenDeleted=Delete`
(`local.mongodb_pvc_retention_when_deleted` in `infra/aws/locals.tf`). Deleting
the StatefulSet therefore lets Kubernetes garbage-collect the
`volumeClaimTemplate` PVC `data-mongodb-0`, after which the EBS CSI driver
deletes the PV and the EBS volume through the StorageClass `Delete` reclaim
path. This happens asynchronously, shortly after `terraform apply` returns.

Before the platform teardown, verify read-only that the ALB is gone and wait
until the MongoDB PVC and PV are gone, while the EBS CSI driver is still running:

```bash
kubectl -n omnivise-iot get pvc          # expect: No resources found
kubectl get pv                           # expect: no omnivise-iot/data-mongodb-0 claim
```

If the PVC does not disappear within a few minutes, do not destroy the platform
and never delete the EBS volume through AWS. Inspect it read-only
(`kubectl -n omnivise-iot describe pvc data-mongodb-0`: ownerReferences,
finalizers, events) and stop for maintainer guidance.

## 13. Platform Teardown

After the credential is revoked and the application state is empty:

```bash
cd infra/aws-platform
export AWS_PROFILE=omnivise-admin
terraform plan -destroy -out=tfplan
terraform show tfplan
# human review and approval
terraform apply tfplan
terraform state list          # expect no output
```

With the dependency graph from §5, Kubernetes/Helm resources are destroyed
before operator access, and the node group before the route, route table
associations and Internet Gateway. The second strict cold-start acceptance (§17)
ran this on a fresh platform lifecycle: the normal saved-plan destroy completed
without `-target` and without state recovery. Do not run a platform destroy
while a Jenkins AWS delivery is in progress, never delete AWS resources
manually, and do not use `-target` in the normal lifecycle.

Troubleshooting: if a normal saved-plan destroy fails on ordering, stop. Inspect
the current state (`terraform state list`), the configuration and a freshly
reviewed `terraform plan -destroy` (`terraform graph -type=plan-destroy` shows
the order). Never improvise manual IAM, EKS, network, AWS or Kubernetes edits or
deletions. Continue only with an explicitly reviewed, maintainer-approved
Terraform recovery plan; targeted or manual recovery is exceptional and is not
part of the normal lifecycle or the successful strict acceptance path.

## 14. Final DOWN-CLEAN Verification

```bash
AWS_PROFILE=omnivise-admin bash scripts/aws-demo.sh status
# STATE: DOWN-CLEAN   (exit 0)
```

Optional read-only cross-checks: `aws eks describe-cluster` returns
`ResourceNotFoundException`; no VPC tagged `Project=omnivise-iot`; the bootstrap
user and delivery/platform IAM roles return `NoSuchEntity`; no EBS volume with
`ebs.csi.aws.com/cluster-name=omnivise-iot`; no ELBv2 load balancer tagged
`elbv2.k8s.aws/cluster=omnivise-iot`.

## 15. Troubleshooting

| Symptom | Action |
| --- | --- |
| `DOWN-DIRTY` | Identify the leftover; remove it through the owning Terraform root or controller path. A remaining bootstrap key can be revoked with `--key-id`. |
| `UP-NO-CREDENTIAL` | Run `issue-credential`. |
| `UP-RESTART-REQUIRED` | Restart Jenkins (§7); re-run `status`. `StartedAt` equal to a file change time is not fresh. |
| `VIOLATION` (identity/access drift) | Restore the declared boundary through the platform saved-plan workflow; never edit IAM/EKS manually. |
| `VIOLATION` (keys / local ID) | Identify keys with `aws iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap`, revoke with `--key-id`, then `issue-credential`. |
| `VIOLATION` (secret files / mounts) | Repair in `local-jenkins-platform`; the tool never creates or rebinds files. |
| `VIOLATION` (cluster not `ACTIVE`) | Wait for transitions and re-run; repair `FAILED` through Terraform. |
| Bootstrap user absent while cluster exists | `VIOLATION` (identity drift); other `get-user` errors are exit 3. |
| Exit 3 `ENVIRONMENT_ERROR` | Fix the named environment issue (credentials, network, throttling, CLI history, endpoint override, missing tool, lock held). No lifecycle conclusion is drawn. |
| Malformed AWS JSON | Exit 3; never treated as absence or zero keys. Re-run; investigate the AWS CLI. |
| `InvalidClientTokenId` after `issue-credential` | Normal IAM propagation; the command retries boundedly, otherwise re-run `status`. |
| Terraform partial apply or destroy | Stop; do not delete resources manually; inspect state and plan; continue only with reviewed saved plans. |
| PVC/PV/EBS residual after app destroy | The PVC should be garbage-collected (`whenDeleted=Delete`, §12). If it persists, stop before platform destroy and inspect it read-only; never delete the EBS volume through AWS. |
| `--key-id` no match / ambiguous | Exit 3; use a longer unique suffix or the full ID. |

## 16. Security Notes

- Never enable shell tracing; the script refuses to run with `set -x`.
- Secrets are never placed in argv, stdout, stderr, logs, temp files or AWS CLI
  history; CLI history must stay disabled and endpoint overrides are refused.
- Bootstrap and delivery probes run with ambient AWS profile/token/web-identity/
  container credentials cleared, `AWS_CONFIG_FILE` and
  `AWS_SHARED_CREDENTIALS_FILE` set to `/dev/null` and the region pinned.
- Temporary kubeconfig, cache and stderr captures live below one private temp
  directory removed on exit/INT/TERM; `~/.kube/config` is never modified.
- `aws eks get-token` via the kubectl exec plugin is the expected non-persistent
  authentication call.
- Every AWS CLI call made through the script pins `--output json`; the
  operator's `output` config or `AWS_DEFAULT_OUTPUT` cannot change what it parses.
- Diagnostics show at most a masked key suffix (`****<last4>`).
- There is no automatic rollback of a created or revoked key.
- Saved Terraform plans may contain secrets; delete them after use.

## 17. Validation Record

### Issue #128 H3/M13 Live Validation (2026-09-21)

Scope: live evidence for the `DOWN` scan selectors; not the full cold-start
acceptance.

- The platform was brought up with reviewed saved plans. The first cold apply
  failed for the namespace and StorageClass because they raced the operator
  access association; a reviewed recovery plan completed it and a convergence
  plan reported `No changes`.
- The application was applied from exact SHA
  `0f806d1c1f1aa6beccc0765bd1216f43717dceea` (all three images proven in GHCR).
- EBS: the MongoDB PVC volume carried `ebs.csi.aws.com/cluster-name=omnivise-iot`
  (plus `KubernetesCluster`, `kubernetes.io/cluster/omnivise-iot=owned`,
  `ebs.csi.aws.com/cluster=true`, `CSIVolumeName`, `kubernetes.io/created-for/*`)
  and no Terraform default tags; the selector was confirmed as-is.
- ALB: the frontend ALB carried `elbv2.k8s.aws/cluster=omnivise-iot`,
  `ingress.k8s.aws/stack=omnivise-iot/frontend` and
  `ingress.k8s.aws/resource=LoadBalancer`; the selector was changed to require
  only the cluster tag.
- Application teardown left the MongoDB PVC/PV/EBS volume, because the
  StatefulSet then used Kubernetes' default `whenDeleted=Retain`; a
  maintainer-approved one-time PVC deletion let the CSI driver remove them. The
  AWS root now sets `whenDeleted=Delete` (§12).
- The platform destroy failed on Helm/namespace (operator access removed first)
  and Internet Gateway detach (node still mapped a public IP). The missing
  dependency edges were added (§5); the pre-fix partial state was finished with
  reviewed Terraform recovery plans, without manual AWS deletion.
- Final `status`: `STATE: DOWN-CLEAN`, exit 0.

The fixed dependency graph was validated end to end on a fresh state by the
second strict cold-start acceptance below.

### Issue #128 First Strict Cold-Start Acceptance

Result: **PARTIAL**.

- Blocker: MongoDB PVC retention after application teardown. The StatefulSet
  `volumeClaimTemplate` PVC `data-mongodb-0` remained `Bound`, because the
  deployed policy effectively retained it.
- The PVC was deleted manually only after the acceptance run, as
  post-acceptance cleanup; this does not change the result.
- Platform teardown itself then completed normally.
- Post-revoke fail-closed behavior (§11) was proven in this run: after the
  credential was revoked, the `projects/omnivise-iot` AWS Jenkins job failed
  closed with `InvalidClientTokenId` before Terraform plan and without
  mutation.

This run stays recorded as PARTIAL. The second run below does not amend it.

### Issue #128 Second Strict Cold-Start Acceptance (2026-09-22)

Result: **PASS**.

Terraform remained authoritative for every AWS, platform and application
mutation, each through saved plan → human approval → exact saved apply. There
was no automatic rollback, no targeted destroy, no manual Terraform state
recovery and no manual infrastructure cleanup.

The run contains two distinct proofs that must not be conflated:

| Proof | Executed by | Source | Contains PVC-retention fix |
| --- | --- | --- | --- |
| AWS delivery | Jenkins `projects/omnivise-iot` | branch `main`, SHA `05d344920a3ac666c7b9576acc033d9d2a2a4c49` | no |
| Automatic MongoDB PVC/PV teardown | operator, pre-merge | `feat/128-aws-demo-readiness` working tree | yes |

Lifecycle and platform bring-up:

- Initial `status`: `STATE: DOWN-CLEAN`.
- Platform saved plan: `Plan: 39 to add, 0 to change, 0 to destroy.`; exact
  saved apply: 39 added, 0 changed, 0 destroyed. The follow-up convergence plan
  reported no changes.
- `status` → `UP-NO-CREDENTIAL`; `issue-credential` → `UP-RESTART-REQUIRED`;
  after the Jenkins restart (§7) `status` → `READY`.

Jenkins `main` delivery proof:

- Job `projects/omnivise-iot`, branch `main`, release SHA
  `05d344920a3ac666c7b9576acc033d9d2a2a4c49`.
- Jenkins saved plan: 12 to add, 0 to change, 0 to destroy; exact saved apply:
  12 added, 0 changed, 0 destroyed.
- Smoke: frontend `GET /` → 200; backend API → 200. Build result `SUCCESS`.
- Jenkins build number: not recorded in this acceptance record.
- Image build/reuse provenance: not recorded in this acceptance record.
- Limitation: `main` did not contain the unmerged PVC-retention fix. The live
  StatefulSet check right after this deployment returned
  `{"whenDeleted":"Retain","whenScaled":"Retain"}`, as expected for `main` at
  that point. This run is not evidence for the PVC fix.

Pre-merge PVC-retention fix proof (operator, not Jenkins):

- The feature working tree configures `whenDeleted = Delete`,
  `whenScaled = Retain` (§12).
- Operator saved plan from `infra/aws` on the feature working tree:
  2 to add, 1 to change, 0 to destroy. The two additions were the TTL-expired
  MongoDB bootstrap Jobs being recreated; the StatefulSet was updated in place
  from `when_deleted = "Retain"` to `when_deleted = "Delete"`.
- Exact saved apply: 2 added, 1 changed, 0 destroyed.
- Live StatefulSet check returned exactly
  `{"whenDeleted":"Delete","whenScaled":"Retain"}`.
- Pre-teardown storage baseline:
  - PVC `data-mongodb-0`: `Bound`, StorageClass `omnivise-iot-gp3`, volume
    `pvc-2c337def-a2fc-4431-afed-46cacd6738ec`;
  - PV `pvc-2c337def-a2fc-4431-afed-46cacd6738ec`: `Bound`, claim
    `omnivise-iot/data-mongodb-0`, reclaim policy `Delete`, StorageClass
    `omnivise-iot-gp3`.

Credential revoke:

- `revoke-credential` returned `STATE: UP-NO-CREDENTIAL` with
  `NEXT: Jenkins AWS delivery is intentionally disabled until a new credential is issued`.
- Post-revoke Jenkins fail-closed check (§11): not revalidated during the
  second strict run; previously proven during the first strict acceptance run.

Application teardown (feature working tree):

- Saved destroy plan: 0 to add, 0 to change, 12 to destroy; exact saved apply:
  0 added, 0 changed, 12 destroyed.
- No manual `kubectl delete pvc` or `kubectl delete pv` was used.
- Afterwards `kubectl -n omnivise-iot get pvc` → `No resources found in
  omnivise-iot namespace.`; `kubectl get pv` → `No resources found.`
- The StatefulSet `whenDeleted=Delete` policy together with the PV `Delete`
  reclaim policy removed the MongoDB PVC and PV automatically. This resolves
  the blocker of the first strict acceptance.

Platform teardown:

- Saved destroy plan: 0 to add, 0 to change, 39 to destroy; exact saved apply:
  0 added, 0 changed, 39 destroyed. Completed normally.

Final state and saved-plan hygiene:

- The application and platform `tfplan` files were removed after use;
  `find infra -maxdepth 3 -type f -name 'tfplan*' -print` returned no output.
- Final `status`:

  ```text
  STATE: DOWN-CLEAN
  NEXT: bring up the AWS platform from the documented saved-plan workflow
  ```

Open follow-up: Jenkins has not yet deployed the PVC-retention fix. After the
fix is merged, a Jenkins `main` AWS delivery must be validated separately,
including the StatefulSet check from §10
(`{"whenDeleted":"Delete","whenScaled":"Retain"}`).
