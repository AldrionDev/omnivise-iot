module "application" {
  source = "../modules/application"

  namespace           = local.namespace
  backend_image_ref   = var.backend_image_ref
  frontend_image_ref  = var.frontend_image_ref
  simulator_image_ref = var.simulator_image_ref

  mongodb_image            = local.mongodb_image
  mongodb_replica_set_name = local.mongodb_replica_set_name
  mongodb_storage_class    = local.mongodb_storage_class
  mongodb_storage_size     = local.mongodb_storage_size

  mongodb_cpu_request    = local.mongodb_cpu_request
  mongodb_cpu_limit      = local.mongodb_cpu_limit
  mongodb_memory_request = local.mongodb_memory_request
  mongodb_memory_limit   = local.mongodb_memory_limit

  mongodb_bootstrap_cpu_request    = local.mongodb_bootstrap_cpu_request
  mongodb_bootstrap_cpu_limit      = local.mongodb_bootstrap_cpu_limit
  mongodb_bootstrap_memory_request = local.mongodb_bootstrap_memory_request
  mongodb_bootstrap_memory_limit   = local.mongodb_bootstrap_memory_limit
}
