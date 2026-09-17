module "application" {
  source = "../modules/application"

  namespace           = kubernetes_namespace_v1.application.metadata[0].name
  backend_image_ref   = var.backend_image_ref
  frontend_image_ref  = var.frontend_image_ref
  simulator_image_ref = var.simulator_image_ref

  image_pull_secret_name = kubernetes_secret_v1.ghcr_pull.metadata[0].name

  simulator_interval_seconds         = 5
  simulator_anomaly_mode             = true
  simulator_anomaly_every_ticks      = 12
  simulator_anomaly_duration_ticks   = 18
  simulator_anomaly_recovery_ticks   = 6
  simulator_max_concurrent_anomalies = 2
  simulator_seed                     = 42

  mongodb_image                        = local.mongodb_image
  mongodb_application_bootstrap_script = file("${path.module}/../../mongo-init.js")
  mongodb_replica_set_name             = local.mongodb_replica_set_name
  mongodb_storage_class                = local.mongodb_storage_class
  mongodb_storage_size                 = local.mongodb_storage_size

  mongodb_cpu_request    = local.mongodb_cpu_request
  mongodb_cpu_limit      = local.mongodb_cpu_limit
  mongodb_memory_request = local.mongodb_memory_request
  mongodb_memory_limit   = local.mongodb_memory_limit

  mongodb_bootstrap_cpu_request    = local.mongodb_bootstrap_cpu_request
  mongodb_bootstrap_cpu_limit      = local.mongodb_bootstrap_cpu_limit
  mongodb_bootstrap_memory_request = local.mongodb_bootstrap_memory_request
  mongodb_bootstrap_memory_limit   = local.mongodb_bootstrap_memory_limit

  backend_cpu_request    = local.backend_cpu_request
  backend_cpu_limit      = local.backend_cpu_limit
  backend_memory_request = local.backend_memory_request
  backend_memory_limit   = local.backend_memory_limit

  frontend_cpu_request    = local.frontend_cpu_request
  frontend_cpu_limit      = local.frontend_cpu_limit
  frontend_memory_request = local.frontend_memory_request
  frontend_memory_limit   = local.frontend_memory_limit

  simulator_cpu_request    = local.simulator_cpu_request
  simulator_cpu_limit      = local.simulator_cpu_limit
  simulator_memory_request = local.simulator_memory_request
  simulator_memory_limit   = local.simulator_memory_limit

  mongodb_wait_cpu_request    = local.mongodb_wait_cpu_request
  mongodb_wait_cpu_limit      = local.mongodb_wait_cpu_limit
  mongodb_wait_memory_request = local.mongodb_wait_memory_request
  mongodb_wait_memory_limit   = local.mongodb_wait_memory_limit
}
