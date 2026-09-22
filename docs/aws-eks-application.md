# AWS EKS Application Root

## Purpose and Scope

```text
infra/aws/
```

is the authoritative Terraform root for deploying the OmniVise application
onto the AWS EKS cluster.

It does **not** own the VPC, EKS cluster, node groups, AWS Load Balancer
Controller capability, or GHCR image publication. Those platform resources are
owned by:

```text
infra/aws-platform/
```

`infra/aws/` consumes the platform outputs and manages the Kubernetes
application resources deployed into the cluster, including the
application-specific public Ingress.

## Terraform State and Workspace

```text
HCP Terraform organization: gabor-toth-personalprojects
Application workspace:      omnivise-iot-aws-app
Platform workspace:         omnivise-iot-aws-platform
```

The `omnivise-iot-aws-app` workspace must use **Local Execution**. The root
consumes the local shared module at `../modules/application`, which HCP
Terraform remote execution cannot resolve.

`infra/aws/`, `infra/aws-platform/`, and `infra/homelab/` use separate
Terraform workspaces and state.

The application root reads platform outputs through `terraform_remote_state`,
but does not own or mutate the platform resources represented by that state.

## Platform Contract Consumption

`infra/aws/platform.tf` reads the platform workspace state through
`terraform_remote_state` and consumes:

- `aws_region`
- `cluster_name`
- `cluster_endpoint`
- `cluster_certificate_authority_data`

These outputs configure the `aws` and `kubernetes` providers in
`infra/aws/providers.tf`.

The application root must not create or manage platform resources such as the
VPC, EKS cluster, node groups, cluster-wide controller IAM roles, or the AWS
Load Balancer Controller Helm release.

## Kubernetes Authentication

The Kubernetes provider authenticates through the AWS EKS token exec plugin:

```text
aws eks get-token --cluster-name <cluster_name> --region <aws_region>
```

Operator commands such as `terraform plan`, `terraform apply`, and read-only
`kubectl` verification must run under an AWS identity authorized for EKS
access.

During acceptance, the environment-specific operator profile was:

```bash
export AWS_PROFILE=omnivise-admin
```

The profile name is not a universal requirement. Any AWS identity with the
required EKS access entry and authorization can be used.

## Application Resources Managed by `infra/aws/`

The AWS application root manages:

- MongoDB StatefulSet, Service, and bootstrap Jobs through the shared
  `../modules/application` module
- backend Deployment and Service
- frontend Deployment and Service
- sensor simulator Deployment
- `ghcr-pull` GHCR image-pull Secret (`registry.tf`)
- public ALB-backed Kubernetes Ingress for the frontend (`ingress.tf`)

The `omnivise-iot` Namespace and the `omnivise-iot-gp3` StorageClass used by
the MongoDB PVC are both cluster-scoped and are owned by `infra/aws-platform/`
instead, since the Jenkins AWS delivery identity is intentionally
namespace-scoped and cannot create or delete either resource. This root only
references them by their known names (`local.namespace` and
`local.mongodb_storage_class`); it does not manage either resource. The shared
`../modules/application` module resolves the Namespace through a
`data.kubernetes_namespace_v1` lookup. See
[AWS EKS Platform](./aws-eks-platform.md#application-namespace-capability) and
[AWS EKS Platform](./aws-eks-platform.md#ebs-csi-storage-capability).

The MongoDB PVC lifecycle is selected per environment through the shared
module's required `mongodb_pvc_retention_when_deleted` input, rendered as the
StatefulSet `persistentVolumeClaimRetentionPolicy.whenDeleted`
(`whenScaled` stays `Retain`). The AWS root sets `Delete`
(`local.mongodb_pvc_retention_when_deleted`): destroying the application lets
Kubernetes garbage-collect `data-mongodb-0` and the EBS CSI driver reclaim its
volume, so no data survives an application destroy. The homelab root sets
`Retain` explicitly, preserving its persistent data.

## Exact-SHA Image Contract

`infra/aws/variables.tf` requires each application image reference to be a full
GHCR reference ending in exactly one 40-character lowercase Git SHA:

```text
backend_image_ref   -> ghcr.io/aldriondev/omnivise-iot-backend:<40-char sha>
frontend_image_ref  -> ghcr.io/aldriondev/omnivise-iot-frontend:<40-char sha>
simulator_image_ref -> ghcr.io/aldriondev/omnivise-iot-simulator:<40-char sha>
```

Each variable has a validation block enforcing this pattern:

```text
^ghcr\.io/aldriondev/omnivise-iot-<component>:[0-9a-f]{40}$
```

`latest`, branch-name tags, and short-SHA tags are rejected.

The deployment contract requires a full 40-character Git-SHA tag identifying
one exact source revision. This is a tag-based release identity, not an image
digest.

## Private GHCR Image Pulls

`infra/aws/registry.tf` manages a Kubernetes Secret named `ghcr-pull` of type:

```text
kubernetes.io/dockerconfigjson
```

The Secret is built from two sensitive Terraform variables:

- `ghcr_username`
- `ghcr_token`

No credential values are stored in this repository or in this documentation.

Because Terraform manages the Kubernetes Secret, the rendered
`.dockerconfigjson`, including the token, is persisted in Terraform state.

The runtime credential should therefore be a minimally scoped read-only GHCR
package token used only for pulling the private OmniVise images.

Do not place GHCR credentials on the command line or commit them. Supply them
through protected:

```text
TF_VAR_ghcr_username
TF_VAR_ghcr_token
```

environment variables or another approved secret-injection mechanism.

## Shared Application Module Compatibility

The shared module at:

```text
infra/modules/application/
```

accepts an optional:

```text
image_pull_secret_name
```

variable with default `null`.

`infra/aws/main.tf` passes:

```text
kubernetes_secret_v1.ghcr_pull.metadata[0].name
```

which wires `ghcr-pull` into `imagePullSecrets` for:

- backend
- frontend
- sensor simulator

`infra/homelab/` does not pass this input, so the value remains `null` and the
homelab pod specifications do not gain an `imagePullSecrets` block.

Homelab runtime behavior therefore remains unchanged.

The shared module's namespace ownership wording is environment-neutral because
the namespace is owned outside the shared module by the relevant environment
root or platform.

## Canonical Application Behavior

AWS reuses the existing shared application module instead of duplicating
application resource definitions.

Notable inherited behavior includes:

- MongoDB bootstrap uses the canonical `../../mongo-init.js` script
- the backend remains reachable internally through the `backend` Service
- the frontend remains the browser-facing application entrypoint
- sensor simulator anomaly behavior remains aligned with the homelab
  configuration

The AWS root supplies environment-specific CPU and memory requests/limits from:

```text
infra/aws/locals.tf
```

## Public AWS Ingress

Issue #120 exposes the AWS deployment through an internet-facing Application
Load Balancer reconciled by the AWS Load Balancer Controller.

The application root owns a Kubernetes Ingress with this routing contract:

```text
ingress class: alb
scheme:        internet-facing
target type:   ip
health check:  /
route:         / -> frontend:80
```

Only the frontend Service is exposed publicly.

The backend and MongoDB Services remain `ClusterIP`.

Browser API and WebSocket traffic continue to use the existing same-origin
frontend Nginx proxy:

```text
Internet
   |
   v
AWS ALB :80
   |
   v
frontend Service :80
   |
   v
frontend Nginx
   | \
   |  \ /api/* and /ws/*
   |          |
   v          v
static UI   backend Service :8080
```

No direct public backend route is created.

The AWS-generated public endpoint is exposed through:

```text
frontend_ingress_hostname
```

Route53, custom DNS, and TLS certificates are outside the scope of this
milestone.

## AWS Load Balancer Controller Dependency

The application Ingress depends on the cluster-wide AWS Load Balancer
Controller capability managed by:

```text
infra/aws-platform/
```

The platform root owns:

- controller Helm release
- dedicated IAM role and policy
- EKS Pod Identity association

The application root owns only the application-specific Ingress object.

Terraform declares the controller and Kubernetes desired state. The controller
then reconciles the downstream AWS load-balancer resources, including the ALB,
target group, listeners, and security-group rules.

Those downstream AWS resources are not separately managed by the application
Terraform root.

## Apply Workflow

The AWS application root follows the saved-plan review boundary used across
OmniVise delivery. Its place in the full demo lifecycle, including teardown, is
described in the [AWS Demo Runbook](./aws-demo-runbook.md).

Example:

```bash
export AWS_PROFILE=omnivise-admin

cd infra/aws

terraform init
terraform validate
terraform fmt -check -recursive
terraform test

terraform plan -out=tfplan
terraform show tfplan

# human review and approval

terraform apply tfplan
```

The approved saved plan is the plan that must be applied. Do not generate a new
plan between approval and apply.

`kubectl` is verification-only. Manual Kubernetes mutation is not part of the
deployment workflow.

## Bootstrap Job TTL Behavior

The MongoDB bootstrap Jobs use:

```text
ttl_seconds_after_finished = 600
```

Kubernetes therefore removes completed bootstrap Jobs after ten minutes.

Terraform still declares those Job resources, so a later full plan can propose
recreating them after the TTL controller has removed them.

This is expected bootstrap-resource drift caused by the Job TTL behavior, not
an application workload failure.

The bootstrap jobs are designed to be idempotent.

For acceptance, fresh convergence plans were taken immediately after apply,
before the completed Jobs were removed again by the Kubernetes TTL controller.

## Verification / Acceptance Evidence

### Issue #119 — AWS Application Root

The AWS application root implementation was verified with:

```text
terraform fmt -check -recursive
terraform validate                          (infra/aws)
terraform test                              (infra/aws)      -> 1 passed, 0 failed
terraform validate                          (infra/homelab)
terraform test                              (infra/homelab)  -> 0 passed, 0 failed
```

The exact saved Terraform plan was successfully applied.

Post-apply, the expected application pods were observed `Ready` / `Running`:

- backend
- frontend
- mongodb
- sensor-simulator

Both MongoDB bootstrap Jobs completed successfully.

An immediate post-apply Terraform plan returned:

```text
No changes. Your infrastructure matches the configuration.
```

This confirms convergence at the time of verification only.

### Issue #120 — Public AWS Ingress

Issue #120 verified that:

- the Kubernetes Ingress reconciled successfully through the `alb` ingress
  class
- the AWS-generated ALB hostname was assigned to the Ingress
- the ALB target group reached `healthy`
- the frontend returned HTTP `200`
- `GET /api/sensors/latest?limit=1` returned HTTP `200` with JSON through the
  frontend Nginx proxy
- `/ws/sensors` completed an HTTP `101 Switching Protocols` WebSocket upgrade
- backend and MongoDB remained internal `ClusterIP` Services
- an immediate post-apply `terraform plan` in `infra/aws/` reported no changes
- an immediate post-apply `terraform plan` in `infra/aws-platform/` reported
  no changes

`kubectl` and AWS CLI were used only for read-only verification.

## Current Non-Goals / Follow-Up Scope

Not implemented by this root:

- multi-target Jenkins delivery (`DEPLOY_TARGET = aws | both`) — planned for
  #122
- end-to-end AWS delivery pipeline verification — planned for #123
- Route53 / custom DNS
- TLS certificates / HTTPS termination

## Outputs

`infra/aws/outputs.tf` exposes:

| Output                      | Description                                                |
| --------------------------- | ---------------------------------------------------------- |
| `namespace`                 | Platform-owned omnivise-iot Namespace this root deploys into |
| `mongodb_service_name`      | Cluster-internal MongoDB Service name                      |
| `mongodb_port`              | TCP port MongoDB listens on                                |
| `mongodb_replica_set_name`  | MongoDB replica-set name                                   |
| `mongodb_storage_class`     | Name of the platform-owned AWS EBS-backed StorageClass used by the MongoDB PVC |
| `backend_image_ref`         | Exact-SHA GHCR backend image deployed by this root         |
| `frontend_image_ref`        | Exact-SHA GHCR frontend image deployed by this root        |
| `simulator_image_ref`       | Exact-SHA GHCR simulator image deployed by this root       |
| `frontend_ingress_hostname` | AWS-generated public ALB hostname for the frontend Ingress |
