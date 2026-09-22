mock_provider "kubernetes" {}

variables {
  namespace                            = "omnivise-iot-test"
  backend_image_ref                    = "example.invalid/backend:test"
  frontend_image_ref                   = "example.invalid/frontend:test"
  simulator_image_ref                  = "example.invalid/simulator:test"
  mongodb_application_bootstrap_script = "print('test')"
  mongodb_storage_size                 = "2Gi"
  mongodb_cpu_request                  = "250m"
  mongodb_cpu_limit                    = "500m"
  mongodb_memory_request               = "512Mi"
  mongodb_memory_limit                 = "1Gi"
  mongodb_bootstrap_cpu_request        = "50m"
  mongodb_bootstrap_cpu_limit          = "100m"
  mongodb_bootstrap_memory_request     = "128Mi"
  mongodb_bootstrap_memory_limit       = "256Mi"
  backend_cpu_request                  = "200m"
  backend_cpu_limit                    = "400m"
  backend_memory_request               = "384Mi"
  backend_memory_limit                 = "768Mi"
  frontend_cpu_request                 = "50m"
  frontend_cpu_limit                   = "100m"
  frontend_memory_request              = "64Mi"
  frontend_memory_limit                = "128Mi"
  simulator_cpu_request                = "100m"
  simulator_cpu_limit                  = "200m"
  simulator_memory_request             = "128Mi"
  simulator_memory_limit               = "256Mi"
  mongodb_wait_cpu_request             = "25m"
  mongodb_wait_cpu_limit               = "50m"
  mongodb_wait_memory_request          = "128Mi"
  mongodb_wait_memory_limit            = "256Mi"
}

run "delete_is_rendered_on_the_statefulset" {
  command = plan

  variables {
    mongodb_pvc_retention_when_deleted = "Delete"
  }

  assert {
    condition     = kubernetes_stateful_set_v1.mongodb.spec[0].persistent_volume_claim_retention_policy[0].when_deleted == "Delete"
    error_message = "whenDeleted=Delete must be rendered on the MongoDB StatefulSet."
  }

  assert {
    condition     = kubernetes_stateful_set_v1.mongodb.spec[0].persistent_volume_claim_retention_policy[0].when_scaled == "Retain"
    error_message = "whenScaled must stay Retain."
  }
}

run "retain_is_rendered_on_the_statefulset" {
  command = plan

  variables {
    mongodb_pvc_retention_when_deleted = "Retain"
  }

  assert {
    condition     = kubernetes_stateful_set_v1.mongodb.spec[0].persistent_volume_claim_retention_policy[0].when_deleted == "Retain"
    error_message = "whenDeleted=Retain must be rendered on the MongoDB StatefulSet."
  }

  assert {
    condition     = kubernetes_stateful_set_v1.mongodb.spec[0].persistent_volume_claim_retention_policy[0].when_scaled == "Retain"
    error_message = "whenScaled must stay Retain."
  }
}

run "unknown_policy_is_rejected" {
  command = plan

  variables {
    mongodb_pvc_retention_when_deleted = "delete"
  }

  expect_failures = [var.mongodb_pvc_retention_when_deleted]
}
