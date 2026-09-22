# This file adds the single-node MongoDB "rs0" replica set (headless Service +
# StatefulSet + one-time bootstrap Job) for the OmniVise IoT application.
# The shared module stays reusable: homelab-specific sizing and the
# storage-class selection come from module inputs supplied by the environment
# root, not from assumptions baked in here.

locals {
  mongodb_port = 27017

  mongodb_labels = {
    "app.kubernetes.io/name"       = "mongodb"
    "app.kubernetes.io/component"  = "database"
    "app.kubernetes.io/part-of"    = "omnivise-iot"
    "app.kubernetes.io/managed-by" = "terraform"
  }

  mongodb_selector_labels = {
    "app.kubernetes.io/name"      = "mongodb"
    "app.kubernetes.io/component" = "database"
  }

  mongodb_namespace = data.kubernetes_namespace_v1.application.metadata[0].name

  # Stable StatefulSet DNS identity of the sole replica-set member. Derived from
  # the resolved namespace so the shared module stays reusable; the homelab root
  # sets namespace = "omnivise-iot", making this resolve to
  # mongodb-0.mongodb.omnivise-iot.svc.cluster.local:27017 (the issue contract).
  mongodb_member_host = "mongodb-0.mongodb.${local.mongodb_namespace}.svc.cluster.local:${local.mongodb_port}"

  mongodb_bootstrap_labels = merge(local.mongodb_labels, {
    "app.kubernetes.io/name" = "mongodb-bootstrap"
  })
}

resource "kubernetes_config_map_v1" "mongodb_application_bootstrap" {
  metadata {
    name      = "mongodb-application-bootstrap"
    namespace = local.mongodb_namespace
    labels    = local.mongodb_labels
  }

  data = {
    "mongo-init.js" = var.mongodb_application_bootstrap_script
  }
}

resource "kubernetes_service_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = local.mongodb_namespace
    labels    = local.mongodb_labels
  }

  spec {
    selector   = local.mongodb_selector_labels
    cluster_ip = "None"

    # Lets the bootstrap Job reach mongodb-0 before its readiness probe passes.
    publish_not_ready_addresses = true

    port {
      name        = "mongodb"
      port        = local.mongodb_port
      target_port = local.mongodb_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_stateful_set_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = local.mongodb_namespace
    labels    = local.mongodb_labels
  }

  # Readiness only turns green after the bootstrap Job elects PRIMARY; blocking
  # apply on rollout would deadlock against the Job.
  wait_for_rollout = false

  spec {
    replicas     = 1
    service_name = "mongodb"

    selector {
      match_labels = local.mongodb_selector_labels
    }

    # whenDeleted is environment-specific; whenScaled stays at the Kubernetes
    # default because replicas is fixed at 1.
    persistent_volume_claim_retention_policy {
      when_deleted = var.mongodb_pvc_retention_when_deleted
      when_scaled  = "Retain"
    }

    template {
      metadata {
        labels = local.mongodb_labels
      }

      spec {
        container {
          name  = "mongodb"
          image = var.mongodb_image

          # The image entrypoint docker-entrypoint.sh is preserved; args only,
          # mirroring the Docker Compose command.
          args = ["--replSet", var.mongodb_replica_set_name, "--bind_ip_all"]

          port {
            name           = "mongodb"
            container_port = local.mongodb_port
            protocol       = "TCP"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }

          resources {
            requests = {
              cpu    = var.mongodb_cpu_request
              memory = var.mongodb_memory_request
            }
            limits = {
              cpu    = var.mongodb_cpu_limit
              memory = var.mongodb_memory_limit
            }
          }

          # Non-mutating: only checks that the process answers.
          startup_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
            }
            failure_threshold = 30
            period_seconds    = 10
            timeout_seconds   = 5
          }

          # Non-mutating: only checks that the process answers.
          liveness_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
            }
            failure_threshold = 6
            period_seconds    = 10
            timeout_seconds   = 5
          }

          # Non-mutating; Ready only when the member is writable PRIMARY; never
          # calls rs.initiate / replSetInitiate / reconfig.
          readiness_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", "quit(db.hello().isWritablePrimary ? 0 : 1)"]
            }
            failure_threshold     = 6
            period_seconds        = 10
            timeout_seconds       = 5
            initial_delay_seconds = 5
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.mongodb_storage_class

        resources {
          requests = {
            storage = var.mongodb_storage_size
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.mongodb]
}

resource "kubernetes_job_v1" "mongodb_bootstrap" {
  metadata {
    name      = "mongodb-bootstrap"
    namespace = local.mongodb_namespace
    labels    = local.mongodb_bootstrap_labels
  }

  wait_for_completion = true

  timeouts {
    create = "20m"
  }

  spec {
    backoff_limit              = 6
    active_deadline_seconds    = 900
    ttl_seconds_after_finished = 600

    template {
      # The name label mongodb-bootstrap deliberately does not match the Service
      # selector, so this pod is never a Service endpoint.
      metadata {
        labels = local.mongodb_bootstrap_labels
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name = "bootstrap"

          # Same image => mongosh matches the server major version.
          image = var.mongodb_image

          command = ["/bin/sh", "-c", file("${path.module}/files/mongodb-bootstrap.sh")]

          env {
            name  = "MONGODB_MEMBER_HOST"
            value = local.mongodb_member_host
          }

          env {
            name  = "MONGODB_REPLICA_SET"
            value = var.mongodb_replica_set_name
          }

          env {
            name  = "BOOTSTRAP_MAX_ATTEMPTS"
            value = "60"
          }

          env {
            name  = "BOOTSTRAP_SLEEP_SECONDS"
            value = "5"
          }

          resources {
            requests = {
              cpu    = var.mongodb_bootstrap_cpu_request
              memory = var.mongodb_bootstrap_memory_request
            }
            limits = {
              cpu    = var.mongodb_bootstrap_cpu_limit
              memory = var.mongodb_bootstrap_memory_limit
            }
          }
        }
      }
    }
  }

  # MUST NOT depend on kubernetes_stateful_set_v1.mongodb: the Job must be able
  # to run concurrently with StatefulSet readiness convergence per the issue's
  # deadlock rule. The Job's own bounded retry loop tolerates mongodb-0 not
  # existing yet.
  depends_on = [kubernetes_service_v1.mongodb]
}

resource "kubernetes_job_v1" "mongodb_application_bootstrap" {
  metadata {
    name      = "mongodb-application-bootstrap"
    namespace = local.mongodb_namespace
    labels = merge(local.mongodb_labels, {
      "app.kubernetes.io/name" = "mongodb-application-bootstrap"
    })
  }

  wait_for_completion = true

  timeouts {
    create = "20m"
  }

  spec {
    backoff_limit              = 1
    active_deadline_seconds    = 900
    ttl_seconds_after_finished = 600

    template {
      metadata {
        labels = merge(local.mongodb_labels, {
          "app.kubernetes.io/name" = "mongodb-application-bootstrap"
        })
        annotations = {
          "omnivise-iot/application-bootstrap-sha256" = sha256(var.mongodb_application_bootstrap_script)
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "bootstrap"
          image = var.mongodb_image

          command = [
            "mongosh",
            "--quiet",
            "--host",
            local.mongodb_member_host,
            "--file",
            "/bootstrap/mongo-init.js",
          ]

          env {
            name  = "MONGO_INITDB_DATABASE"
            value = local.mongo_database
          }

          volume_mount {
            name       = "bootstrap-script"
            mount_path = "/bootstrap"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.mongodb_bootstrap_cpu_request
              memory = var.mongodb_bootstrap_memory_request
            }
            limits = {
              cpu    = var.mongodb_bootstrap_cpu_limit
              memory = var.mongodb_bootstrap_memory_limit
            }
          }
        }

        volume {
          name = "bootstrap-script"

          config_map {
            name = kubernetes_config_map_v1.mongodb_application_bootstrap.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_job_v1.mongodb_bootstrap,
  ]
}
