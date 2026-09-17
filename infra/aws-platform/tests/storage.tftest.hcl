mock_provider "aws" {}
mock_provider "kubernetes" {}

run "storage_contract" {
  command = plan

  assert {
    condition     = var.pod_identity_agent_addon_version == "v1.3.10-eksbuild.3"
    error_message = "The Pod Identity Agent add-on version must remain explicitly pinned."
  }

  assert {
    condition     = var.ebs_csi_addon_version == "v1.66.0-eksbuild.1"
    error_message = "The EBS CSI add-on version must remain explicitly pinned."
  }

  assert {
    condition     = aws_eks_addon.pod_identity_agent.addon_name == "eks-pod-identity-agent"
    error_message = "The platform must install the EKS Pod Identity Agent managed add-on."
  }

  assert {
    condition     = aws_eks_addon.ebs_csi.addon_name == "aws-ebs-csi-driver"
    error_message = "The platform must install the Amazon EBS CSI Driver managed add-on."
  }

  assert {
    condition = (
      length(aws_eks_addon.ebs_csi.pod_identity_association) == 1 &&
      one(aws_eks_addon.ebs_csi.pod_identity_association).service_account == "ebs-csi-controller-sa"
    )
    error_message = "The EBS CSI add-on must have exactly one Pod Identity association for ebs-csi-controller-sa."
  }

  assert {
    condition     = aws_iam_role.ebs_csi.name != aws_iam_role.eks_node.name
    error_message = "EBS CSI permissions must not be assigned to the EKS node role."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi_cluster_scoped.role == aws_iam_role.ebs_csi.name
    error_message = "The EBS CSI policy must attach to the dedicated controller role."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi_cluster_scoped.policy_arn == "arn:aws:iam::aws:policy/AmazonEBSCSIDriverEKSClusterScopedPolicy"
    error_message = "The EBS CSI controller must use the cluster-scoped AWS managed policy."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "The EBS CSI role must trust EKS Pod Identity."
  }

  assert {
    condition = (
      contains(
        jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Action,
        "sts:AssumeRole"
      ) &&
      contains(
        jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Action,
        "sts:TagSession"
      )
    )
    error_message = "The Pod Identity trust must allow AssumeRole and TagSession."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] == var.cluster_name
    error_message = "The EBS CSI trust must be restricted to the intended EKS cluster."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == "kube-system"
    error_message = "The EBS CSI trust must be restricted to kube-system."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "ebs-csi-controller-sa"
    error_message = "The EBS CSI trust must be restricted to ebs-csi-controller-sa."
  }
}

run "storage_class_contract" {
  command = plan

  assert {
    condition     = kubernetes_storage_class_v1.gp3.metadata[0].name == "omnivise-iot-gp3"
    error_message = "The platform-owned StorageClass must keep its known contract name."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.storage_provisioner == "ebs.csi.aws.com"
    error_message = "The platform-owned StorageClass must use the Amazon EBS CSI provisioner."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.parameters["type"] == "gp3"
    error_message = "The platform-owned StorageClass must provision gp3 volumes."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.volume_binding_mode == "WaitForFirstConsumer"
    error_message = "The platform-owned StorageClass must use WaitForFirstConsumer volume binding."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.reclaim_policy == "Delete"
    error_message = "The platform-owned StorageClass must use Delete reclaim policy."
  }
}
