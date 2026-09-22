# AWS EKS Platform Foundation

## Scope

The AWS platform foundation is managed from:

```text
infra/aws-platform/
```

This Terraform root owns only AWS platform infrastructure required by the
OmniVise EKS target. Kubernetes application workloads are intentionally managed
separately.

The initial platform consists of:

- one VPC in `eu-north-1`;
- two public subnets across `eu-north-1a` and `eu-north-1b`;
- one Internet Gateway and public default route;
- no NAT Gateway;
- one Amazon EKS cluster running Kubernetes `1.36`;
- one managed node group using `t3.medium`;
- node-group scaling of min `1`, desired `1`, max `2`;
- dedicated Terraform-managed EKS cluster and node IAM roles;
- an EKS access entry for the approved operator role;
- a declarative, Terraform-managed IAM identity and namespace-scoped EKS
  access entry for Jenkins AWS delivery (issue #139).

Application workloads and application-specific Ingress resources are managed
separately by `infra/aws/`.

This platform root owns the cluster-wide AWS Load Balancer Controller capability
required by AWS application ingress. DNS, TLS certificates, GHCR publication,
and Jenkins AWS delivery remain outside this platform root.

## Terraform State Boundary

The platform uses the literal HCP Terraform workspace:

```text
omnivise-iot-aws-platform
```

The workspace uses **Local Execution**.

Terraform therefore executes on the operator or Jenkins host, while HCP
Terraform provides authoritative remote state and state locking.

There is no local-state fallback.

The EKS application root is separate:

```text
infra/aws/
```

and uses its own HCP Terraform workspace/state. Platform resources and
Kubernetes application resources must not share Terraform state.

Current state boundaries are:

```text
infra/homelab/       -> omnivise-iot-k8s
infra/aws-platform/  -> omnivise-iot-aws-platform
infra/aws/           -> separate AWS application workspace
```

## Network Design

The initial portfolio environment deliberately favours simplicity and low cost.

```text
VPC:              10.20.0.0/16
Public subnet A:  10.20.0.0/20   eu-north-1a
Public subnet B:  10.20.16.0/20  eu-north-1b
```

Both worker subnets are public and automatically assign public IPv4 addresses.

The public route table sends:

```text
0.0.0.0/0 -> Internet Gateway
```

No NAT Gateway or Elastic IP is provisioned.

Worker nodes are not given an unrestricted inbound Internet security-group rule
by this Terraform root.

## EKS API Access

The EKS control-plane endpoint has both public and private access enabled.

For this short-lived portfolio/interview environment, the public Kubernetes API
endpoint intentionally allows:

```text
0.0.0.0/0
```

This is a conscious convenience trade-off rather than a production security
posture. Public network reachability does not grant Kubernetes access: AWS IAM
authentication and EKS authorization remain mandatory.

Implicit cluster-creator administrator access is disabled.

The approved operator role is granted cluster administration through an EKS
access entry and the AWS-managed `AmazonEKSClusterAdminPolicy`.

This choice avoids requiring a Terraform plan/apply whenever the operator's
dynamic public IP address changes.

The public OmniVise application endpoint is a separate concern.
Application Internet exposure is implemented through the AWS ingress/load-balancer layer rather than through the Kubernetes API endpoint.

## IAM

Terraform creates dedicated IAM roles for:

- the EKS control plane;
- the EKS managed node group.

The cluster role trusts `eks.amazonaws.com`.

The node role trusts `ec2.amazonaws.com` and receives the AWS-managed policies
required for EKS worker-node operation, VPC CNI operation, and registry access
needed by the EKS node runtime.

Pre-existing account-level EKS roles are not implicitly reused.

## Cost Model

This is intentionally a short-lived demonstration environment.

The design avoids a NAT Gateway and starts with a single `t3.medium` worker node
to limit recurring cost while still leaving enough capacity for the planned
OmniVise workload and Kubernetes system components.

Billable AWS infrastructure must not be applied without explicit maintainer
review of the exact saved Terraform plan.

The environment should be destroyed when it is no longer needed for development,
demonstration, or interviews.

## Saved-Plan Workflow

Platform mutations use the same review boundary as the rest of OmniVise
delivery:

```text
terraform init
terraform validate
terraform fmt -check -recursive
terraform test
terraform plan -out=tfplan
terraform show tfplan
human review and approval
terraform apply tfplan
```

The approved saved plan is the plan that must be applied. Do not re-plan between
approval and apply.

Terraform plan files are local execution artifacts and must not be committed.

After apply, verification is read-only. A second Terraform plan must also
confirm that the resulting infrastructure is converged.

## Post-Apply Verification

At minimum verify:

- EKS cluster status is `ACTIVE`;
- managed node group status is `ACTIVE`;
- expected worker node becomes Kubernetes `Ready`;
- cluster version is `1.36`;
- the two expected public subnets are attached;
- the operator access entry exists;
- the `omnivise-iot-jenkins-bootstrap` IAM user and `omnivise-iot-jenkins-delivery`
  IAM role exist, with only the declared inline policies (exclusive guards
  report no out-of-band managed attachments);
- the Jenkins delivery EKS access entry exists and is namespace-scoped to
  `omnivise-iot` with `AmazonEKSAdminPolicy` — never cluster-scoped;
- no unexpected unrestricted worker-node inbound security-group rule exists;
- a subsequent Terraform plan reports no changes.

`kubectl` is used only for verification. Terraform remains the authoritative
mutation mechanism.

## Destroy

Destroy is an explicit operator action and must be reviewed before execution.
The end-to-end teardown order (credential revoke, application, platform,
`DOWN-CLEAN` check) is in the [AWS Demo Runbook](./aws-demo-runbook.md).

Before destroying the platform, first remove application-layer resources that
depend on it.

Then inspect the destroy plan before executing it:

```text
terraform plan -destroy -out=tfplan
terraform show tfplan
terraform apply tfplan
```

Do not destroy shared or unrelated AWS resources. The platform Terraform state
must contain only resources owned by this project.

### Known Destroy-Ordering Constraints

These constraints were observed during previous teardowns of this
environment. The platform-internal ones are now encoded in the Terraform
dependency graph, so a normal full `terraform plan -destroy` orders them
correctly (and a cold create uses the same edges in the forward direction):

| Resource | Explicit `depends_on` | Create effect | Destroy effect |
| --- | --- | --- | --- |
| `kubernetes_namespace_v1.application`, `kubernetes_storage_class_v1.gp3`, `helm_release.aws_load_balancer_controller` | `aws_eks_access_policy_association.operator_cluster_admin` | Kubernetes/Helm calls start only after operator cluster-admin access exists | operator access is removed only after these resources are gone |
| `aws_eks_node_group.this` | `aws_route.public_internet`, `aws_route_table_association.public` | public-subnet nodes join only after the Internet route exists | the route, route-table associations and Internet Gateway are removed only after the nodes (and their public IPs) are gone |

A normal full `terraform plan` / `apply` and `terraform plan -destroy` use
these configuration edges. The issue #128 second strict cold-start acceptance
proved them on a fresh platform lifecycle: one saved-plan apply created all 39
platform resources and one saved-plan destroy removed them, without targeted
destroy or state recovery (see the
[AWS Demo Runbook validation record](./aws-demo-runbook.md#17-validation-record)).

The application-before-platform and no-in-flight-Jenkins-run constraints
below remain operational requirements across the two Terraform roots.

- **Application before platform.** `infra/aws` application resources must be
  fully destroyed before `infra/aws-platform` is destroyed. Since issue #139,
  this also applies to the Jenkins delivery identity: the platform destroy
  removes the `omnivise-iot-jenkins-delivery` EKS access entry along with
  everything else in `infra/aws-platform/delivery_identity.tf`, so Jenkins
  loses the ability to reach the cluster at all once the platform is gone.
- **No Jenkins AWS delivery in progress.** Do not begin a platform destroy
  while a Jenkins `DEPLOY_TARGET=aws` (or `both`) run is in progress. A
  platform destroy that lands mid-run can pull the delivery role's cluster
  access out from under an in-flight `infra/aws` apply.
- **Kubernetes/Helm-managed platform resources must be removed while the
  operator EKS access entry still exists.** `helm_release.aws_load_balancer_controller`,
  the `kubernetes_namespace_v1` and `kubernetes_storage_class_v1` resources,
  and any other Kubernetes-API-managed platform resource are authorized
  through the operator's cluster-admin access entry (`access.tf`), not
  through a Terraform dependency edge. Deleting that access entry before
  those resources are torn down breaks Kubernetes authorization mid-destroy
  and is exactly what happened during a previous platform destroy recovery.
  Let Terraform destroy Kubernetes/Helm-managed resources before, or without
  separately touching, the operator access entry.
- **Node group before network teardown.** The managed EKS node group must be
  fully gone before Internet Gateway, subnet, or VPC teardown can complete —
  live EC2 instances and their public addresses in a subnet can block IGW
  detachment and subnet/VPC deletion.

If a broader, systematic hardening of the platform destroy dependency graph
is needed beyond recording these constraints, it should be tracked as its
own follow-up issue rather than folded into a feature issue like #139.

## AWS Load Balancer Controller Capability

Public application ingress depends on the cluster-wide AWS Load Balancer
Controller capability managed by:

```text
infra/aws-platform/
```

The platform owns:

- AWS Load Balancer Controller Helm release;
- dedicated IAM role and IAM policy;
- EKS Pod Identity association for
  `kube-system/aws-load-balancer-controller`.

The controller is installed from the AWS EKS Helm repository with the chart
version pinned in Terraform. It uses EKS Pod Identity rather than IRSA/OIDC or
worker-node IAM permissions.

The controller IAM trust is restricted through Pod Identity request tags to:

```text
cluster:         omnivise-iot
namespace:       kube-system
service account: aws-load-balancer-controller
```

Application-specific Ingress resources are not owned by this root. They are
declared by `infra/aws/`; the controller reconciles those Kubernetes resources
into AWS ALB, target-group, listener, and security-group resources.

The existing EKS cluster security group is also attached to the managed worker
node. Its self-referencing ingress rule permits the controller webhook traffic
required between the EKS control plane and worker nodes, including TCP 9443, so
no additional worker-node ingress rule is required for this capability.

### Runtime Acceptance

Issue #120 verified that:

- the exact saved platform Terraform plan added only the controller IAM role,
  IAM policy, policy attachment, Pod Identity association, and Helm release;
- the apply completed with `5 added, 0 changed, 0 destroyed`;
- both AWS Load Balancer Controller pods reached `1/1 Running`;
- the expected EKS Pod Identity association exists for
  `kube-system/aws-load-balancer-controller`;
- an immediate post-apply Terraform plan reported no changes.

`kubectl` and AWS CLI were used only for read-only verification.

## EBS CSI Storage Capability

Persistent EBS storage is a platform capability owned by:

```text
infra/aws-platform/
```

The platform manages the following Amazon EKS add-ons for Kubernetes `1.36`:

```text
eks-pod-identity-agent  v1.3.10-eksbuild.3
aws-ebs-csi-driver      v1.66.0-eksbuild.1
```

The Amazon EBS CSI Driver uses EKS Pod Identity rather than IRSA or worker-node
IAM permissions.

The EBS CSI controller service account:

```text
kube-system/ebs-csi-controller-sa
```

is associated with the dedicated Terraform-managed IAM role:

```text
omnivise-iot-aws-ebs-csi
```

The role trusts `pods.eks.amazonaws.com` and is restricted through Pod Identity
request tags to:

```text
cluster:         omnivise-iot
namespace:       kube-system
service account: ebs-csi-controller-sa
```

The role receives only the AWS-managed:

```text
AmazonEBSCSIDriverEKSClusterScopedPolicy
```

policy. EBS CSI permissions are not attached to the EKS worker-node IAM role.

The EBS CSI add-on owns the Pod Identity association.

The platform also owns the persistent, cluster-scoped `omnivise-iot-gp3`
StorageClass (`storage.tf`) consumed by the MongoDB PVC in
`infra/aws/`. This ownership is intentional: the Jenkins AWS delivery identity
for `infra/aws/` is namespace-scoped via EKS access entry and cannot manage
cluster-scoped `storageclasses.storage.k8s.io` resources. `infra/aws/` only
references the StorageClass by its known name; it does not manage the
resource.

```text
provisioner:       ebs.csi.aws.com
type:              gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy:     Delete
```

### Runtime Acceptance

Issue #126 verified dynamic EBS provisioning with a temporary StorageClass using:

```text
provisioner:       ebs.csi.aws.com
type:              gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy:     Delete
```

Acceptance proved that:

- the temporary PVC reached `Bound`;
- the verification pod reached `Running`;
- the pod successfully mounted the dynamically provisioned EBS volume;
- a sentinel value could be written to and read back from the mounted filesystem;
- the resulting PersistentVolume used the `ebs.csi.aws.com` CSI driver;
- the backing AWS volume used `gp3`;
- the EBS volume and scheduled Kubernetes node were in the same Availability Zone;
- the volume carried `ebs.csi.aws.com/cluster-name=omnivise-iot`;
- deleting the temporary PVC deleted the PersistentVolume;
- deleting the temporary PVC also deleted the backing EBS volume;
- the temporary StorageClass and namespace were deleted;
- no acceptance-test Kubernetes or EBS resources remained afterward.

MongoDB and other application workloads remain outside this platform root.
They are owned by the separate AWS application Terraform root.

After acceptance, a fresh Terraform plan reported:

```text
No changes. Your infrastructure matches the configuration.
```

with detailed exit code `0`.

## Application Namespace Capability

The platform also owns the cluster-scoped `omnivise-iot` Namespace
(`namespace.tf`) consumed by the application resources in `infra/aws/`. This
ownership is intentional and mirrors the `omnivise-iot-gp3` StorageClass
decision above: the Jenkins AWS delivery identity for `infra/aws/` is
namespace-scoped via EKS access entry and cannot create or delete the
cluster-scoped Namespace it needs to deploy into. On a freshly recreated
cluster, a Jenkins-first `DEPLOY_TARGET=aws` run could not otherwise succeed.
`infra/aws/` only references the Namespace by its known name
(`local.namespace`); the shared `../modules/application` module resolves it
through a `data.kubernetes_namespace_v1` lookup and never creates or manages
it. See [AWS EKS Application](./aws-eks-application.md#application-resources-managed-by-infraaws).

### Migration Precondition

This ownership moved from `infra/aws/` to this platform root in issue #138.
No `terraform state mv` or `import` was used, because the specific precondition
for #138 was already satisfied: both the `omnivise-iot-aws-app` and
`omnivise-iot-aws-platform` HCP Terraform workspaces held no resources
(`terraform state list` was empty in both) at the time of the change, since the
AWS demo environment had been fully torn down beforehand (DOWN-CLEAN). This
DOWN-CLEAN precondition was specific to #138's circumstances, not a universal
requirement for every future ownership transfer between these roots.

If an equivalent ownership transfer is ever needed while live resources exist
in either workspace, it requires either an explicit, reviewed Terraform state
migration appropriate to the two separate HCP Terraform workspaces involved,
or a controlled teardown before the code change is applied — never an
unplanned cutover. In either case, the two roots must never simultaneously
manage or attempt to recreate the same Namespace; exactly one root owns the
`kubernetes_namespace_v1.application` resource at a time.

The first fresh live proof of this ownership model was completed under
issue #139 on 2026-09-20: Jenkins ran `DEPLOY_TARGET=aws` against a freshly
applied platform with no prior `infra/aws` state and with no operator-run
application apply. The saved application plan contained 12 additions, the
exact saved plan applied successfully, and post-deploy HTTP smoke checks
returned 200 for both the frontend and backend API. This completed the
deferred issue #138 live proof.

## Jenkins Delivery Identity Capability

The platform's Terraform declares the complete Jenkins AWS delivery
identity (`delivery_identity.tf`), consumed by the separate `infra/aws`
application root through the `Jenkinsfile`'s AWS delivery stages:

- IAM user `omnivise-iot-jenkins-bootstrap`, with exactly one inline policy
  (`sts:AssumeRole` on the delivery role) and no access key, login profile, or
  managed policy attachment;
- IAM role `omnivise-iot-jenkins-delivery`, trusted only by the bootstrap
  user, with exactly one inline policy (`eks:DescribeCluster` on this
  cluster) and no managed policy attachment;
- an EKS access entry for the delivery role, associated with
  `AmazonEKSAdminPolicy` scoped to the `omnivise-iot` namespace only, never
  cluster-scoped.

This ownership is intentional and ephemeral — mirroring the StorageClass
and Namespace decisions above: the identity has a stable name and definition,
while its AWS instance is created by the platform apply and destroyed by the
platform destroy, exactly like every other platform-owned resource. The
one-time migration from the manually provisioned issue #118 identity was
completed under issue #139 on 2026-09-20. No manual IAM mutation is required
to recreate the identity after a torn-down environment is rebuilt. At the
end of the recorded verification the environment was torn down again, so no
live bootstrap user or delivery role remains; the next platform apply will
recreate them from this Terraform definition. Full
identity/credential/rotation contract:
[AWS Delivery Identity Contract](./aws-delivery-identity.md).

The AWS access key used to authenticate as the bootstrap user is
deliberately **not** part of this Terraform definition — see
`docs/aws-delivery-identity.md` section 5.2 and issue #128 for the key's own
lifecycle.

### Migration Procedure (One-Time, Human-Executed, Completed)

This procedure was executed once by the operator on 2026-09-20 to retire the
identity that issue #118 provisioned manually and replace it with the
Terraform-managed one above. It is recorded here as historical verification
for issue #139, not as a repeatable operational step:

1. Precondition: issue #138 merged; both `omnivise-iot-aws-app` and
   `omnivise-iot-aws-platform` HCP Terraform workspaces empty; no Jenkins AWS
   run in progress.
2. Record the non-secret facts of the existing manual identity (policy
   names, attached policies) for the Verification Record.
3. As operator: delete the manual bootstrap user's access keys, inline
   policy, and the user itself; delete the manual delivery role's inline
   policy and the role itself. The cluster-bound manual EKS access entry is
   already gone with the cluster.
4. Verify `aws iam get-user --user-name omnivise-iot-jenkins-bootstrap` and
   `aws iam get-role --role-name omnivise-iot-jenkins-delivery` both return
   `NoSuchEntity`.
5. Platform `terraform plan -out=tfplan` → review (IAM section explicitly)
   → `terraform apply tfplan`; see the Live Verification Record below for
   the Kubernetes/Helm authentication-context recovery this required → a
   subsequent `terraform plan` reports no changes.

### Post-Apply Checks

In addition to the general checks above:

- an interim AWS access key is created manually for
  `omnivise-iot-jenkins-bootstrap` (until issue #128's tooling exists), and
  the full #118 identity chain still holds: bootstrap caller resolves to the
  user ARN; bootstrap `eks:DescribeCluster` and `sts:AssumeRole` on
  `AdminAssumeRole` are both denied; bootstrap can assume the delivery role;
  delivery `eks:DescribeCluster` succeeds; delivery `eks:ListClusters` and
  `iam:ListUsers` are both denied; `kubectl auth can-i create namespaces`
  as the delivery role is `no`; `kubectl auth can-i create deployments -n
  omnivise-iot` as the delivery role is `yes`;
- a Jenkins-first `DEPLOY_TARGET=aws` run against the freshly applied
  platform succeeded with no operator-run `infra/aws` apply, completing the
  deferred #138 live proof.

### Live Teardown Verification

The required teardown sequence for issue #139 was executed successfully on
2026-09-20. The Jenkinsfile does not provide an automated destroy stage for
`infra/aws` — there is no Jenkins destroy job to invoke. Application teardown
was therefore an operator-run action using the same Terraform saved-plan
workflow this repository already uses for every destroy (see "Destroy"
above), authenticated through the same delivery-role assumption chain the
Jenkinsfile itself uses for applies (`aws-omnivise-iot-bootstrap` assumes
`omnivise-iot-jenkins-delivery`), not a Jenkins-triggered action:

1. Complete the AWS application teardown (`infra/aws`) —
   `terraform plan -destroy -out=tfplan` → review → `terraform apply
   tfplan`, the same saved-plan pattern the platform's own Destroy section
   above uses — while the interim Jenkins bootstrap credential and the
   platform-owned delivery identity are still valid.
2. Verify the application root's teardown is complete: `terraform state
   list` against the `omnivise-iot-aws-app` workspace reports no resources.
   This is not DOWN-CLEAN — the platform is still up at this point, because
   the delivery identity is still needed for step 1 and platform destroy
   happens later, in step 4.
3. Revoke/delete the interim bootstrap access key.
4. Destroy `infra/aws-platform` (the platform's own Destroy section above).
5. Verify the Terraform-managed `omnivise-iot-jenkins-bootstrap` IAM user
   and `omnivise-iot-jenkins-delivery` IAM role both return `NoSuchEntity`.

Application teardown must precede platform teardown (see "Known
Destroy-Ordering Constraints" above). The interim access key is
intentionally revoked in step 3, before the platform destroy in step 4 —
that revocation is the normal credential-lifecycle path;
`force_destroy = true` on the bootstrap IAM user (section 5.2 of
[AWS Delivery Identity Contract](./aws-delivery-identity.md)) is only a
teardown safety net for step 4, not a substitute for step 3.

### Issue #139 Live Verification Record (2026-09-20)

The complete create/use/destroy lifecycle was verified against the live AWS
account:

- the pre-existing manually provisioned issue #118 bootstrap user and
  delivery role were inspected, their permission boundaries recorded, then
  their access key, inline policies, user, and role were removed; both
  principals returned `NoSuchEntity` before Terraform recreation;
- the first platform saved-plan apply created the AWS platform and
  Terraform-managed delivery identity. Its Kubernetes/Helm resources failed
  only because the local shell was still authenticated as
  `cli-access-gtoth` rather than `AdminAssumeRole`; after explicitly assuming
  `AdminAssumeRole`, a new reviewed recovery plan contained exactly three
  additions, applied successfully, and a subsequent plan reported no
  changes;
- an interim bootstrap access key was created outside Terraform and loaded
  into the existing `aws-omnivise-iot-bootstrap` Jenkins credential.
  `platform/verify-delivery-capabilities` completed successfully;
- the bootstrap principal had no direct EKS access and could not assume
  `AdminAssumeRole`; it could assume only
  `omnivise-iot-jenkins-delivery`. The delivery role could describe only the
  target EKS cluster at the AWS API layer, while Kubernetes authorization
  returned `no` for namespace creation and `yes` for deployment creation
  inside `omnivise-iot`;
- Jenkins then performed the first fresh-cluster `DEPLOY_TARGET=aws`
  application delivery from exact Git SHA
  `0f806d1c1f1aa6beccc0765bd1216f43717dceea`. The reviewed saved plan
  contained 12 additions, the exact saved plan applied 12 additions, and
  post-deploy frontend/backend smoke checks both returned HTTP 200;
- application teardown used a reviewed `infra/aws` destroy plan. Ten
  resources remained to destroy because the two TTL bootstrap Jobs had
  already expired; the exact saved plan destroyed those ten resources and
  the application Terraform state became empty;
- the interim bootstrap access key was explicitly revoked before platform
  teardown;
- platform teardown followed the recorded ordering constraints: first the
  Helm release, Namespace, and StorageClass; then the Pod Identity
  association together with the Pod Identity Agent and EBS CSI addons; then
  the managed node group; then the remaining platform resources. No EKS node
  EC2 instances remained before network teardown;
- the final platform destroy removed 32 remaining resources. The platform
  Terraform state became empty, and both
  `omnivise-iot-jenkins-bootstrap` and
  `omnivise-iot-jenkins-delivery` returned `NoSuchEntity`.

The resulting state is DOWN-CLEAN for the AWS demo environment. The stable
Terraform definition remains in the repository; a future platform apply can
recreate the delivery identity without reconstructing the former manual IAM
setup.
