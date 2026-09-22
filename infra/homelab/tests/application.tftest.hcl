mock_provider "kubernetes" {}

run "mongodb_pvc_is_retained" {
  command = plan

  variables {
    backend_image_ref   = "example.invalid/backend:test"
    frontend_image_ref  = "example.invalid/frontend:test"
    simulator_image_ref = "example.invalid/simulator:test"
    kubeconfig_path     = "/dev/null"
    kubernetes_context  = "test"
  }

  assert {
    condition     = local.mongodb_pvc_retention_when_deleted == "Retain"
    error_message = "The homelab MongoDB StatefulSet must retain its PVC when the StatefulSet is deleted."
  }
}
