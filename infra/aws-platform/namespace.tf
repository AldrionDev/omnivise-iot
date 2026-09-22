resource "kubernetes_namespace_v1" "application" {
  metadata {
    name = local.application_namespace

    labels = {
      "app.kubernetes.io/name"       = local.application
      "app.kubernetes.io/part-of"    = local.application
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # Kubernetes API calls are authorized by the operator cluster-admin access
  # entry. Create after it; destroy before it (reverse order).
  depends_on = [
    aws_eks_access_policy_association.operator_cluster_admin,
  ]
}
