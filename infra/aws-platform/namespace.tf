resource "kubernetes_namespace_v1" "application" {
  metadata {
    name = local.application_namespace

    labels = {
      "app.kubernetes.io/name"       = local.application
      "app.kubernetes.io/part-of"    = local.application
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
