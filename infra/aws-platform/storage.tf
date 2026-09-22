resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = local.gp3_storage_class_name

    labels = {
      "app.kubernetes.io/name"       = local.application
      "app.kubernetes.io/part-of"    = local.application
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type = "gp3"
  }

  # Kubernetes API calls are authorized by the operator cluster-admin access
  # entry. Create after it; destroy before it (reverse order).
  depends_on = [
    aws_eks_access_policy_association.operator_cluster_admin,
  ]
}
