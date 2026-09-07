locals {
  application = "omnivise-iot"
  namespace   = "omnivise-iot"

  # Approved homelab H2 MongoDB budget values supplied to the shared application module.
  mongodb_image            = "mongo:7.0"
  mongodb_replica_set_name = "rs0"
  mongodb_storage_class    = "local-path"
  mongodb_storage_size     = "2Gi"

  mongodb_cpu_request    = "250m"
  mongodb_cpu_limit      = "500m"
  mongodb_memory_request = "512Mi"
  mongodb_memory_limit   = "1Gi"

  mongodb_bootstrap_cpu_request    = "50m"
  mongodb_bootstrap_cpu_limit      = "100m"
  mongodb_bootstrap_memory_request = "64Mi"
  mongodb_bootstrap_memory_limit   = "128Mi"
}
