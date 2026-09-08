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

  # Bootstrap Job. Memory sized up from 64Mi/128Mi after the Job container was
  # OOMKilled (exit 137) repeatedly at the 128Mi limit during homelab #53 apply.
  mongodb_bootstrap_cpu_request    = "50m"
  mongodb_bootstrap_cpu_limit      = "100m"
  mongodb_bootstrap_memory_request = "128Mi"
  mongodb_bootstrap_memory_limit   = "256Mi"

  # Approved homelab H3 application-workload resource budget supplied to the shared application module.
  backend_cpu_request    = "200m"
  backend_cpu_limit      = "400m"
  backend_memory_request = "384Mi"
  backend_memory_limit   = "768Mi"

  frontend_cpu_request    = "50m"
  frontend_cpu_limit      = "100m"
  frontend_memory_request = "64Mi"
  frontend_memory_limit   = "128Mi"

  simulator_cpu_request    = "100m"
  simulator_cpu_limit      = "200m"
  simulator_memory_request = "128Mi"
  simulator_memory_limit   = "256Mi"

  # MongoDB PRIMARY-wait init container (backend + simulator). Memory sized up
  # from 32Mi/64Mi after this container was OOMKilled (exit 137) at the 64Mi
  # limit during homelab #53 apply. Now equal to the simulator app container and
  # below the backend one; Kubernetes charges a pod max( max(init), sum(app) )
  # per resource, so it does not raise either pod's effective ResourceQuota cost.
  mongodb_wait_cpu_request    = "25m"
  mongodb_wait_cpu_limit      = "50m"
  mongodb_wait_memory_request = "128Mi"
  mongodb_wait_memory_limit   = "256Mi"
}
