# This file adds the three OmniVise application workloads (backend, frontend,
# sensor-simulator) Deployments plus the backend and frontend cluster-internal
# Services. The shared module stays environment-neutral; all sizing comes from
# module inputs supplied by the environment root.

locals {
  app_namespace     = data.kubernetes_namespace_v1.application.metadata[0].name
  backend_port      = 8080
  frontend_port     = 80
  mongo_uri         = "mongodb://mongodb:27017/?replicaSet=rs0" # deployment-safe URI contract (#33); byte-identical to docker-compose
  mongo_database    = "omnivise_iot"
  sensor_collection = "sensor_readings" # preserves the Docker Compose sensor collection contract
  sensor_interval   = "5"               # 5 s == 5000 ms; preserves the Docker Compose simulation interval contract
  mongodb_wait_host = "mongodb:27017"   # cluster-internal MongoDB Service, short name keeps the module environment-neutral

  # FQDN backend authority for the frontend Nginx runtime name lookup; namespace
  # comes from the module input so the module stays environment-neutral. This is
  # an upstream host:port target, not a DNS-server address.
  frontend_backend_upstream = "backend.${local.app_namespace}.svc.cluster.local:${local.backend_port}"

  common_labels = {
    "app.kubernetes.io/part-of"    = "omnivise-iot"
    "app.kubernetes.io/managed-by" = "terraform"
  }

  backend_selector_labels   = { "app.kubernetes.io/name" = "backend", "app.kubernetes.io/component" = "api" }
  frontend_selector_labels  = { "app.kubernetes.io/name" = "frontend", "app.kubernetes.io/component" = "web" }
  simulator_selector_labels = { "app.kubernetes.io/name" = "sensor-simulator", "app.kubernetes.io/component" = "simulator" }

  backend_labels   = merge(local.common_labels, local.backend_selector_labels)
  frontend_labels  = merge(local.common_labels, local.frontend_selector_labels)
  simulator_labels = merge(local.common_labels, local.simulator_selector_labels)
}

# ResourceQuota arithmetic (the ResourceQuota resource itself is owned by
# homelab-platform#41 and is deliberately NOT created here):
#
#   Max concurrent footprint =
#     H2 (MongoDB          req 250m / 512Mi, lim 500m / 1Gi;
#         bootstrap Job    req  50m /  64Mi, lim 100m / 128Mi)
#   + H3 (backend          req 200m / 384Mi, lim 400m / 768Mi;
#         frontend         req  50m /  64Mi, lim 100m / 128Mi;
#         simulator        req 100m / 128Mi, lim 200m / 256Mi)
#
#   Totals: requests 650m CPU / 1152Mi; limits 1300m CPU / 2304Mi.
#   Platform quota (homelab-platform#41): requests 1000m / 2048Mi;
#   limits 2000m / 4096Mi. Headroom stays positive.
#
#   Each mongodb-wait init container (req 25m / 32Mi, lim 50m / 64Mi) is smaller
#   than its pod's application container, and Kubernetes charges a pod
#   max( max(init container), sum(app containers) ) per resource, so the init
#   containers do not raise any pod's effective ResourceQuota cost above the H3
#   totals above.

resource "kubernetes_deployment_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = local.app_namespace
    labels    = local.backend_labels
  }

  # The pod is not Ready until the init gate + /health pass; blocking apply on
  # rollout mirrors the MongoDB StatefulSet deadlock-avoidance rationale.
  wait_for_rollout = false

  spec {
    replicas = 1

    selector {
      match_labels = local.backend_selector_labels
    }

    template {
      metadata {
        labels = local.backend_labels
      }

      spec {
        init_container {
          name    = "mongodb-wait"
          image   = var.mongodb_image
          command = ["/bin/sh", "-c", file("${path.module}/files/mongodb-wait.sh")]

          env {
            name  = "MONGODB_WAIT_HOST"
            value = local.mongodb_wait_host
          }

          env {
            name  = "WAIT_MAX_ATTEMPTS"
            value = "60"
          }

          env {
            name  = "WAIT_SLEEP_SECONDS"
            value = "5"
          }

          resources {
            requests = {
              cpu    = var.mongodb_wait_cpu_request
              memory = var.mongodb_wait_memory_request
            }
            limits = {
              cpu    = var.mongodb_wait_cpu_limit
              memory = var.mongodb_wait_memory_limit
            }
          }
        }

        container {
          name  = "backend"
          image = var.backend_image_ref

          port {
            name           = "http"
            container_port = local.backend_port
            protocol       = "TCP"
          }

          env {
            name  = "BACKEND_PORT"
            value = "8080"
          }

          env {
            name  = "MONGO_DATABASE"
            value = local.mongo_database
          }

          env {
            name  = "MONGO_URI"
            value = local.mongo_uri
          }

          resources {
            requests = {
              cpu    = var.backend_cpu_request
              memory = var.backend_memory_request
            }
            limits = {
              cpu    = var.backend_cpu_limit
              memory = var.backend_memory_limit
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.backend_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.backend_port
            }
            initial_delay_seconds = 15
            period_seconds        = 20
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.mongodb]
}

resource "kubernetes_service_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = local.app_namespace
    labels    = local.backend_labels
  }

  spec {
    selector = local.backend_selector_labels
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = local.backend_port
      target_port = local.backend_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = local.app_namespace
    labels    = local.frontend_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.frontend_selector_labels
    }

    template {
      metadata {
        labels = local.frontend_labels
      }

      spec {
        # No init_container. The frontend container now carries exactly one env
        # var, BACKEND_UPSTREAM, set to the backend Service FQDN so Nginx's
        # runtime name lookup (using the DNS server discovered by the #37 image
        # entrypoint's local-DNS discovery, enabled in frontend/Dockerfile) can
        # resolve it deterministically in-cluster. Still NO DNS-server IP and NO
        # CoreDNS address set here; DNS server discovery is still the image
        # entrypoint's job. nginx.conf hardcodes `listen 80`.
        container {
          name  = "frontend"
          image = var.frontend_image_ref

          env {
            name  = "BACKEND_UPSTREAM"
            value = local.frontend_backend_upstream
          }

          port {
            name           = "http"
            container_port = local.frontend_port
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = var.frontend_cpu_request
              memory = var.frontend_memory_request
            }
            limits = {
              cpu    = var.frontend_cpu_limit
              memory = var.frontend_memory_limit
            }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.frontend_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          liveness_probe {
            http_get {
              path = "/"
              port = local.frontend_port
            }
            initial_delay_seconds = 10
            period_seconds        = 20
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = local.app_namespace
    labels    = local.frontend_labels
  }

  spec {
    selector = local.frontend_selector_labels
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = local.frontend_port
      target_port = local.frontend_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment_v1" "sensor_simulator" {
  metadata {
    name      = "sensor-simulator"
    namespace = local.app_namespace
    labels    = local.simulator_labels
  }

  # Has the init gate and no probes; would otherwise report Ready before MongoDB
  # is PRIMARY.
  wait_for_rollout = false

  spec {
    replicas = 1

    selector {
      match_labels = local.simulator_selector_labels
    }

    template {
      metadata {
        labels = local.simulator_labels
      }

      spec {
        init_container {
          name    = "mongodb-wait"
          image   = var.mongodb_image
          command = ["/bin/sh", "-c", file("${path.module}/files/mongodb-wait.sh")]

          env {
            name  = "MONGODB_WAIT_HOST"
            value = local.mongodb_wait_host
          }

          env {
            name  = "WAIT_MAX_ATTEMPTS"
            value = "60"
          }

          env {
            name  = "WAIT_SLEEP_SECONDS"
            value = "5"
          }

          resources {
            requests = {
              cpu    = var.mongodb_wait_cpu_request
              memory = var.mongodb_wait_memory_request
            }
            limits = {
              cpu    = var.mongodb_wait_cpu_limit
              memory = var.mongodb_wait_memory_limit
            }
          }
        }

        container {
          name  = "sensor-simulator"
          image = var.simulator_image_ref

          # No port block: the simulator exposes nothing.
          env {
            name  = "MONGO_URI"
            value = local.mongo_uri
          }

          env {
            name  = "MONGO_DATABASE"
            value = local.mongo_database
          }

          env {
            name  = "MONGO_COLLECTION"
            value = local.sensor_collection
          }

          env {
            name  = "INTERVAL_SECONDS"
            value = local.sensor_interval
          }

          resources {
            requests = {
              cpu    = var.simulator_cpu_request
              memory = var.simulator_memory_request
            }
            limits = {
              cpu    = var.simulator_cpu_limit
              memory = var.simulator_memory_limit
            }
          }

          # No readiness_probe / liveness_probe: the "Simulator health model"
          # section of the issue forbids inventing a fake endpoint. Kubernetes
          # uses process-exit + Deployment restart.
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.mongodb]
}

# NOTE: no kubernetes_service_v1 for the simulator - it must have no Service.
