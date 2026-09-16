mock_provider "aws" {}

run "load_balancer_controller_identity_contract" {
  command = plan

  assert {
    condition = (
      jsondecode(
        aws_iam_role.aws_load_balancer_controller.assume_role_policy
      ).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    )
    error_message = "The AWS Load Balancer Controller role must trust EKS Pod Identity."
  }

  assert {
    condition = (
      contains(
        jsondecode(
          aws_iam_role.aws_load_balancer_controller.assume_role_policy
        ).Statement[0].Action,
        "sts:AssumeRole"
      ) &&
      contains(
        jsondecode(
          aws_iam_role.aws_load_balancer_controller.assume_role_policy
        ).Statement[0].Action,
        "sts:TagSession"
      )
    )
    error_message = "The AWS Load Balancer Controller Pod Identity trust must allow AssumeRole and TagSession."
  }

  assert {
    condition = (
      jsondecode(
        aws_iam_role.aws_load_balancer_controller.assume_role_policy
      ).Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] == var.cluster_name
    )
    error_message = "The AWS Load Balancer Controller trust must be restricted to the intended EKS cluster."
  }

  assert {
    condition = (
      jsondecode(
        aws_iam_role.aws_load_balancer_controller.assume_role_policy
      ).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == "kube-system"
    )
    error_message = "The AWS Load Balancer Controller trust must be restricted to kube-system."
  }

  assert {
    condition = (
      jsondecode(
        aws_iam_role.aws_load_balancer_controller.assume_role_policy
      ).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "aws-load-balancer-controller"
    )
    error_message = "The AWS Load Balancer Controller trust must be restricted to its dedicated service account."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.aws_load_balancer_controller.namespace == "kube-system" &&
      aws_eks_pod_identity_association.aws_load_balancer_controller.service_account == "aws-load-balancer-controller"
    )
    error_message = "The AWS Load Balancer Controller must use Pod Identity in kube-system with the expected service account."
  }

  assert {
    condition = (
      aws_iam_role.aws_load_balancer_controller.name != aws_iam_role.eks_node.name &&
      aws_iam_role.aws_load_balancer_controller.name != aws_iam_role.ebs_csi.name
    )
    error_message = "The AWS Load Balancer Controller must use a dedicated IAM role."
  }

  assert {
    condition = (
      aws_iam_role_policy_attachment.aws_load_balancer_controller.role ==
      aws_iam_role.aws_load_balancer_controller.name
    )
    error_message = "The AWS Load Balancer Controller IAM policy must attach to its dedicated role."
  }

  assert {
    condition = (
      helm_release.aws_load_balancer_controller.chart == "aws-load-balancer-controller" &&
      helm_release.aws_load_balancer_controller.version == "1.14.0" &&
      helm_release.aws_load_balancer_controller.namespace == "kube-system"
    )
    error_message = "The AWS Load Balancer Controller Helm release must use the pinned chart and kube-system namespace."
  }

  assert {
    condition = one([
      for item in helm_release.aws_load_balancer_controller.set :
      item.value
      if item.name == "serviceAccount.name"
    ]) == "aws-load-balancer-controller"

    error_message = "The AWS Load Balancer Controller Helm release must use the expected service account."
  }

}
