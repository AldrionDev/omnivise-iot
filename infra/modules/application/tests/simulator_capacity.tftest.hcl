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

run "capacity_equality_is_valid_and_propagated" {
  command = plan

  variables {
    simulator_interval_seconds         = 5
    simulator_anomaly_mode             = true
    simulator_anomaly_every_ticks      = 12
    simulator_anomaly_duration_ticks   = 18
    simulator_anomaly_recovery_ticks   = 6
    simulator_max_concurrent_anomalies = 2
    simulator_seed                     = 42
  }

  assert {
    condition = one([
      for env in kubernetes_deployment_v1.sensor_simulator.spec[0].template[0].spec[0].container[0].env : env.value
      if env.name == "ANOMALY_RECOVERY_TICKS"
    ]) == "6"
    error_message = "The effective recovery must be propagated to the simulator container."
  }

  assert {
    condition = one([
      for env in kubernetes_deployment_v1.sensor_simulator.spec[0].template[0].spec[0].container[0].env : env.value
      if env.name == "MAX_CONCURRENT_ANOMALIES"
    ]) == "2"
    error_message = "Max concurrency must be propagated to the simulator container."
  }
}

run "omitted_recovery_uses_legacy_derivation_and_default_concurrency" {
  command = plan

  assert {
    condition = one([
      for env in kubernetes_deployment_v1.sensor_simulator.spec[0].template[0].spec[0].container[0].env : env.value
      if env.name == "ANOMALY_RECOVERY_TICKS"
    ]) == "3"
    error_message = "Omitted recovery must derive max(2, duration / 2)."
  }

  assert {
    condition = one([
      for env in kubernetes_deployment_v1.sensor_simulator.spec[0].template[0].spec[0].container[0].env : env.value
      if env.name == "MAX_CONCURRENT_ANOMALIES"
    ]) == "1"
    error_message = "Simulator max concurrency must default to one."
  }
}

run "over_capacity_is_invalid" {
  command = plan

  variables {
    simulator_anomaly_mode             = true
    simulator_anomaly_every_ticks      = 12
    simulator_anomaly_duration_ticks   = 19
    simulator_anomaly_recovery_ticks   = 6
    simulator_max_concurrent_anomalies = 2
  }

  expect_failures = [kubernetes_deployment_v1.sensor_simulator]
}
