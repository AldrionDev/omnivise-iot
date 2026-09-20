mock_provider "aws" {}
mock_provider "kubernetes" {}

run "namespace_contract" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.application.metadata[0].name == "omnivise-iot"
    error_message = "The platform-owned Namespace must keep its known contract name."
  }

  assert {
    condition     = kubernetes_namespace_v1.application.metadata[0].labels["app.kubernetes.io/name"] == "omnivise-iot"
    error_message = "The platform-owned Namespace must carry the omnivise-iot name label."
  }

  assert {
    condition     = kubernetes_namespace_v1.application.metadata[0].labels["app.kubernetes.io/part-of"] == "omnivise-iot"
    error_message = "The platform-owned Namespace must carry the omnivise-iot part-of label."
  }

  assert {
    condition     = kubernetes_namespace_v1.application.metadata[0].labels["app.kubernetes.io/managed-by"] == "terraform"
    error_message = "The platform-owned Namespace must be labeled as Terraform-managed."
  }

  assert {
    condition     = local.application_namespace == "omnivise-iot"
    error_message = "The application_namespace local must match the platform-owned Namespace name."
  }
}
