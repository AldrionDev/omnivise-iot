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

* one VPC in `eu-north-1`;
* two public subnets across `eu-north-1a` and `eu-north-1b`;
* one Internet Gateway and public default route;
* no NAT Gateway;
* one Amazon EKS cluster running Kubernetes `1.36`;
* one managed node group using `t3.medium`;
* node-group scaling of min `1`, desired `1`, max `2`;
* dedicated Terraform-managed EKS cluster and node IAM roles;
* an EKS access entry for the approved operator role.

Application workloads, ingress, load balancers, DNS, GHCR publication, and
Jenkins AWS delivery are outside this platform root.

## Terraform State Boundary

The platform uses the literal HCP Terraform workspace:

```text
omnivise-iot-aws-platform
```

The workspace uses **Local Execution**.

Terraform therefore executes on the operator or Jenkins host, while HCP
Terraform provides authoritative remote state and state locking.

There is no local-state fallback.

The future EKS application root is separate:

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

The public OmniVise application endpoint is a separate concern. Application
Internet exposure will be implemented through the AWS ingress/load-balancer
layer rather than through the Kubernetes API endpoint.

## IAM

Terraform creates dedicated IAM roles for:

* the EKS control plane;
* the EKS managed node group.

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

* EKS cluster status is `ACTIVE`;
* managed node group status is `ACTIVE`;
* expected worker node becomes Kubernetes `Ready`;
* cluster version is `1.36`;
* the two expected public subnets are attached;
* the operator access entry exists;
* no unexpected unrestricted worker-node inbound security-group rule exists;
* a subsequent Terraform plan reports no changes.

`kubectl` is used only for verification. Terraform remains the authoritative
mutation mechanism.

## Destroy

Destroy is an explicit operator action and must be reviewed before execution.

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
