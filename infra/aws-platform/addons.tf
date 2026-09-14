resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.pod_identity_agent_addon_version

  depends_on = [
    aws_eks_node_group.this,
  ]

  tags = {
    Name = "${local.application}-${var.environment}-pod-identity-agent"
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.ebs_csi_addon_version

  pod_identity_association {
    service_account = "ebs-csi-controller-sa"
    role_arn        = aws_iam_role.ebs_csi.arn
  }

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.ebs_csi_cluster_scoped,
  ]

  tags = {
    Name = "${local.application}-${var.environment}-ebs-csi"
  }
}
