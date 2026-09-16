# AWS EKS Application Root

## Purpose and Scope

```text
infra/aws/
```

is the authoritative Terraform root for deploying the OmniVise application
onto the AWS EKS cluster.

It does **not** own the VPC, EKS cluster, node groups, ingress/load balancer,
or GHCR image publication. Those platform resources are owned by:

```text
infra/aws-platform/
```

`infra/aws/` only consumes the platform's outputs and deploys Kubernetes
application resources into the cluster the platform provides.

## Terraform State and Workspace

```text
HCP Terraform organization: gabor-toth-personalprojects
Application workspace:      omnivise-iot-aws-app
Platform workspace (consumed via terraform_remote_state):
                             omnivise-iot-aws-platform
```

The `omnivise-iot-aws-app` workspace must use **Local Execution**. The root
consumes the local shared module at `../modules/application`, which HCP
Terraform's remote execution environment cannot resolve.

`infra/aws/`, `infra/aws-platform/`, and `infra/homelab/` use separate
Terraform workspaces and state. The application root reads the platform
workspace's outputs through `terraform_remote_state` but does not own or
mutate platform resources.

## Platform Contract Consumption

`infra/aws/platform.tf` reads the platform workspace's state through
`terraform_remote_state` and consumes:

* `aws_region`
* `cluster_name`
* `cluster_endpoint`
* `cluster_certificate_authority_data`

These outputs configure the `aws` and `kubernetes` providers in
`infra/aws/providers.tf`. The application root must not create or manage
platform resources (VPC, EKS cluster, node groups, IAM roles for the
platform).

## Kubernetes Authentication

The Kubernetes provider authenticates using the AWS EKS token exec plugin:

```text
aws eks get-token --cluster-name <cluster_name> --region <aws_region>
```

Operator commands (`terraform plan`, `terraform apply`, `kubectl`) must run
under an AWS identity authorized for EKS access on the target cluster. During
acceptance, the operator profile used was:

```bash
export AWS_PROFILE=omnivise-admin
```

This profile name is specific to the current environment and is not a
universal requirement — any AWS identity with the correct EKS access entry
works.

## Application Resources Managed by `infra/aws/`

* `omnivise-iot` Kubernetes namespace (`namespace.tf`)
* `omnivise-iot-gp3` StorageClass using the `ebs.csi.aws.com` provisioner
  (`storage.tf`)
* MongoDB StatefulSet, Service, and bootstrap Jobs, via the shared
  `../modules/application` module
* backend Deployment and Service
* frontend Deployment and Service
* sensor simulator Deployment
* `ghcr-pull` GHCR image-pull Secret (`registry.tf`)

## Exact-SHA Image Contract

`infra/aws/variables.tf` requires each image reference to be a full GHCR
reference ending in exactly one 40-character lowercase Git SHA:

```text
backend_image_ref   -> ghcr.io/aldriondev/omnivise-iot-backend:<40-char sha>
frontend_image_ref  -> ghcr.io/aldriondev/omnivise-iot-frontend:<40-char sha>
simulator_image_ref -> ghcr.io/aldriondev/omnivise-iot-simulator:<40-char sha>
```

Each variable has a `validation` block enforcing this pattern:

```text
^ghcr\.io/aldriondev/omnivise-iot-<component>:[0-9a-f]{40}$
```

`latest`, branch-name tags, and short-SHA tags are all rejected. The
deployment contract requires a full 40-character Git-SHA tag identifying one
exact source revision. This is a tag-based release identity, not an image
digest.

## Private GHCR Image Pulls

`infra/aws/registry.tf` manages a Kubernetes Secret named `ghcr-pull` of type
`kubernetes.io/dockerconfigjson`, built from two sensitive Terraform
variables:

* `ghcr_username`
* `ghcr_token`

No real credential values are stored in this repository or in this
documentation.

Because Terraform manages this Secret, the rendered `.dockerconfigjson`
(including the token) is persisted in Terraform state. Use a minimal,
read-only GHCR package token scoped to pulling the OmniVise packages for
`ghcr_token`, not a broadly scoped personal token.

## Shared Application Module Compatibility

The shared module at `infra/modules/application/` gained an optional
`image_pull_secret_name` variable (default `null`):

* `infra/aws/main.tf` passes `image_pull_secret_name = kubernetes_secret_v1.ghcr_pull.metadata[0].name`,
  wiring `ghcr-pull` into `imagePullSecrets` on the backend, frontend, and
  simulator pod specs via a `dynamic "image_pull_secrets"` block.
* `infra/homelab/` passes nothing, so `image_pull_secret_name` stays `null`
  and homelab pod specs carry no `imagePullSecrets` — homelab behavior is
  unchanged.

The module's namespace-ownership comment and output description were
generalized from "owned by the homelab-platform repository" to "owned
outside this shared module by the environment-specific Terraform root or
platform," since namespace ownership is environment-specific and no longer
exclusively a homelab concern.

## Canonical Application Behavior

AWS reuses the existing shared `infra/modules/application/` module rather
than duplicating resource definitions. Notable inherited behavior:

* MongoDB bootstrap still uses the canonical `../../mongo-init.js` script,
  read via `file("${path.module}/../../mongo-init.js")` in `infra/aws/main.tf`.
* Sensor simulator anomaly configuration (`simulator_anomaly_mode = true`,
  `simulator_anomaly_every_ticks = 12`, `simulator_anomaly_duration_ticks = 18`,
  `simulator_anomaly_recovery_ticks = 6`, `simulator_max_concurrent_anomalies = 2`,
  `simulator_seed = 42`) is currently wired in `infra/aws/main.tf` aligned
  with the homelab defaults.

Container resource requests/limits (CPU/memory for MongoDB, backend,
frontend, simulator, and the MongoDB-wait init container) are supplied per
environment in `infra/aws/locals.tf`; see that file for exact values rather
than duplicating them here.

## Apply Workflow

The AWS application root follows the same saved-plan review boundary as the
rest of OmniVise delivery. No manual `kubectl` mutation is performed against
the EKS cluster; `kubectl` is verification-only.

```bash
export AWS_PROFILE=omnivise-admin   # environment-specific example

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

The approved saved plan is the plan that must be applied; do not re-plan
between approval and apply. Never pass `ghcr_username`/`ghcr_token` values in
shell history or commit them — supply them via protected `TF_VAR_ghcr_username`
/ `TF_VAR_ghcr_token` environment variables, or another approved
secret-injection mechanism.

## Verification / Acceptance Evidence

The implementation was verified with:

```text
terraform fmt -check -recursive
terraform validate                          (infra/aws)
terraform test                              (infra/aws)   -> 1 passed, 0 failed
terraform validate                          (infra/homelab)
terraform test                              (infra/homelab) -> 0 passed, 0 failed
```

The exact saved plan was successfully applied. Post-apply, all expected EKS
pods were observed `Ready`/`Running`:

* backend
* frontend
* mongodb
* sensor-simulator

Both MongoDB bootstrap Jobs completed with status `Completed`.

An immediate post-apply `terraform plan` returned:

```text
No changes. Your infrastructure matches the configuration.
```

This confirms convergence at the moment of verification only; it is not a
claim about long-term drift behavior.

## Current Non-Goals / Follow-Up Scope

Not implemented by this root:

* ingress / load balancer for public application access — planned for #120
* multi-target Jenkins delivery (`DEPLOY_TARGET = aws | both`) — planned for
  #122
* end-to-end AWS delivery pipeline verification — planned for #123

## Outputs

`infra/aws/outputs.tf` exposes:

| Output | Description |
| --- | --- |
| `namespace` | AWS application namespace managed by this root |
| `mongodb_service_name` | Cluster-internal MongoDB Service name |
| `mongodb_port` | TCP port MongoDB listens on |
| `mongodb_replica_set_name` | MongoDB replica-set name |
| `mongodb_storage_class` | AWS EBS-backed StorageClass used by the MongoDB PVC |
| `backend_image_ref` | Exact-SHA GHCR backend image deployed by this root |
| `frontend_image_ref` | Exact-SHA GHCR frontend image deployed by this root |
| `simulator_image_ref` | Exact-SHA GHCR simulator image deployed by this root |
