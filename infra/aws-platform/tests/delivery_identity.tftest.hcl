mock_provider "aws" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

run "delivery_identity_contract" {
  command = plan

  # Several invariants below assert that one resource's ARN is embedded in
  # another resource's policy JSON. ARNs are computed attributes normally
  # unknown until after apply; override them to known mock values so the
  # plan-time assertions below can evaluate.
  override_resource {
    target = aws_iam_user.jenkins_bootstrap
    values = {
      arn = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
    override_during = plan
  }

  override_resource {
    target = aws_iam_role.jenkins_delivery
    values = {
      arn = "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
    }
    override_during = plan
  }

  override_resource {
    target = aws_eks_cluster.this
    values = {
      arn = "arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      certificate_authority = [
        {
          data = "bW9jaw=="
        }
      ]
    }
    override_during = plan
  }


  # Invariant 1: bootstrap user — exactly one inline policy, exactly
  # sts:AssumeRole on exactly the delivery role ARN; exclusive guards present
  # with no managed attachments; force_destroy; no access key/login profile.
  assert {
    condition     = aws_iam_user.jenkins_bootstrap.name == "omnivise-iot-jenkins-bootstrap"
    error_message = "The Jenkins bootstrap IAM user must keep its known contract name."
  }

  assert {
    condition     = aws_iam_user.jenkins_bootstrap.force_destroy == true
    error_message = "The Jenkins bootstrap IAM user must set force_destroy so a platform destroy cannot leave an orphaned access key behind."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_user_policy.jenkins_bootstrap_assume_delivery.policy).Statement) == 1 &&
      jsondecode(aws_iam_user_policy.jenkins_bootstrap_assume_delivery.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_user_policy.jenkins_bootstrap_assume_delivery.policy).Statement[0].Action == "sts:AssumeRole" &&
      jsondecode(aws_iam_user_policy.jenkins_bootstrap_assume_delivery.policy).Statement[0].Resource == aws_iam_role.jenkins_delivery.arn
    )
    error_message = "The bootstrap user's inline policy must grant exactly sts:AssumeRole on exactly the delivery role ARN."
  }

  assert {
    condition = (
      length(aws_iam_user_policies_exclusive.jenkins_bootstrap.policy_names) == 1 &&
      contains(aws_iam_user_policies_exclusive.jenkins_bootstrap.policy_names, aws_iam_user_policy.jenkins_bootstrap_assume_delivery.name)
    )
    error_message = "The bootstrap user's inline policy set must be exclusively managed and contain only the assume-delivery policy."
  }

  assert {
    condition     = length(aws_iam_user_policy_attachments_exclusive.jenkins_bootstrap.policy_arns) == 0
    error_message = "The bootstrap user must have no managed policy attachments."
  }

  # Invariant 2: delivery role trust — exactly one principal, the bootstrap
  # user ARN; action exactly sts:AssumeRole; no AssumeRoleWithWebIdentity,
  # Federated, or Service principal.
  assert {
    condition = (
      length(jsondecode(aws_iam_role.jenkins_delivery.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.jenkins_delivery.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.jenkins_delivery.assume_role_policy).Statement[0].Action == "sts:AssumeRole" &&
      jsondecode(aws_iam_role.jenkins_delivery.assume_role_policy).Statement[0].Principal.AWS == aws_iam_user.jenkins_bootstrap.arn
    )
    error_message = "The delivery role's trust policy must admit exactly the bootstrap user via sts:AssumeRole."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.jenkins_delivery.assume_role_policy).Statement[0].Principal) == ["AWS"]
    error_message = "The delivery role's trust policy must not admit a Federated or Service principal — only Principal.AWS."
  }

  # Invariant 3: delivery role permissions — exactly eks:DescribeCluster on
  # the cluster ARN; no managed attachments.
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.jenkins_delivery_describe_cluster.policy).Statement) == 1 &&
      jsondecode(aws_iam_role_policy.jenkins_delivery_describe_cluster.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.jenkins_delivery_describe_cluster.policy).Statement[0].Action == "eks:DescribeCluster" &&
      jsondecode(aws_iam_role_policy.jenkins_delivery_describe_cluster.policy).Statement[0].Resource == aws_eks_cluster.this.arn
    )
    error_message = "The delivery role's inline policy must grant exactly eks:DescribeCluster on exactly this cluster."
  }

  assert {
    condition = (
      length(aws_iam_role_policies_exclusive.jenkins_delivery.policy_names) == 1 &&
      contains(aws_iam_role_policies_exclusive.jenkins_delivery.policy_names, aws_iam_role_policy.jenkins_delivery_describe_cluster.name)
    )
    error_message = "The delivery role's inline policy set must be exclusively managed and contain only the DescribeCluster policy."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachments_exclusive.jenkins_delivery.policy_arns) == 0
    error_message = "The delivery role must have no managed policy attachments (no AdministratorAccess or any other managed policy)."
  }

  # Invariant 4: access association — AmazonEKSAdminPolicy, namespace scope,
  # namespaces exactly ["omnivise-iot"].
  assert {
    condition     = aws_eks_access_entry.jenkins_delivery.principal_arn == aws_iam_role.jenkins_delivery.arn
    error_message = "The Jenkins delivery EKS access entry must be for the delivery role."
  }

  assert {
    condition     = aws_eks_access_entry.jenkins_delivery.type == "STANDARD"
    error_message = "The Jenkins delivery EKS access entry must use the STANDARD type."
  }

  assert {
    condition     = aws_eks_access_policy_association.jenkins_delivery_namespace_admin.principal_arn == aws_eks_access_entry.jenkins_delivery.principal_arn
    error_message = "The Jenkins delivery access association must be wired through the EKS access entry's principal_arn, preserving the implicit destroy-order dependency between association and entry."
  }

  assert {
    condition     = aws_eks_access_policy_association.jenkins_delivery_namespace_admin.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
    error_message = "The Jenkins delivery access association must use AmazonEKSAdminPolicy."
  }

  assert {
    condition = (
      aws_eks_access_policy_association.jenkins_delivery_namespace_admin.access_scope[0].type == "namespace" &&
      length(aws_eks_access_policy_association.jenkins_delivery_namespace_admin.access_scope[0].namespaces) == 1 &&
      contains(aws_eks_access_policy_association.jenkins_delivery_namespace_admin.access_scope[0].namespaces, "omnivise-iot")
    )
    error_message = "The Jenkins delivery access association must be namespace-scoped to exactly omnivise-iot."
  }

  # Invariant 5: names are exact literals.
  assert {
    condition     = aws_iam_role.jenkins_delivery.name == "omnivise-iot-jenkins-delivery"
    error_message = "The Jenkins delivery IAM role must keep its known contract name."
  }

  # Cross-check: the platform's cluster-admin operator association remains
  # unrelated to and distinct from the Jenkins delivery association.
  assert {
    condition     = aws_eks_access_policy_association.operator_cluster_admin.principal_arn != aws_eks_access_entry.jenkins_delivery.principal_arn
    error_message = "The Jenkins delivery principal must never be the same principal as the cluster-admin operator association."
  }
}

run "operator_principal_arn_rejects_jenkins_delivery_role" {
  command = plan

  variables {
    operator_principal_arn = "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
  }

  expect_failures = [
    var.operator_principal_arn,
  ]
}

run "operator_principal_arn_rejects_jenkins_bootstrap_user" {
  command = plan

  variables {
    operator_principal_arn = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
  }

  expect_failures = [
    var.operator_principal_arn,
  ]
}
