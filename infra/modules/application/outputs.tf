output "namespace" {
  description = "Resolved name of the platform-owned namespace application resources target."
  value       = data.kubernetes_namespace_v1.application.metadata[0].name
}

output "mongodb_service_name" {
  description = "Cluster-internal headless Service name for MongoDB."
  value       = kubernetes_service_v1.mongodb.metadata[0].name
}

output "mongodb_port" {
  description = "TCP port MongoDB listens on."
  value       = local.mongodb_port
}

output "mongodb_replica_set_name" {
  description = "MongoDB replica-set name."
  value       = var.mongodb_replica_set_name
}
