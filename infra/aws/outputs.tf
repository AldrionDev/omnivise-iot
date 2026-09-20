output "namespace" {
  description = "Platform-owned omnivise-iot Namespace this Terraform root deploys application resources into."
  value       = module.application.namespace
}

output "mongodb_service_name" {
  description = "Cluster-internal MongoDB Service name."
  value       = module.application.mongodb_service_name
}

output "mongodb_port" {
  description = "TCP port MongoDB listens on."
  value       = module.application.mongodb_port
}

output "mongodb_replica_set_name" {
  description = "MongoDB replica-set name."
  value       = module.application.mongodb_replica_set_name
}

output "mongodb_storage_class" {
  description = "Name of the platform-owned AWS EBS-backed StorageClass used by the MongoDB PVC. The StorageClass itself is managed by infra/aws-platform; this root only references it by name."
  value       = local.mongodb_storage_class
}

output "backend_image_ref" {
  description = "Exact-SHA GHCR backend image deployed by this root."
  value       = var.backend_image_ref
}

output "frontend_image_ref" {
  description = "Exact-SHA GHCR frontend image deployed by this root."
  value       = var.frontend_image_ref
}

output "simulator_image_ref" {
  description = "Exact-SHA GHCR simulator image deployed by this root."
  value       = var.simulator_image_ref
}

output "frontend_ingress_hostname" {
  description = "AWS-generated public ALB hostname for the OmniVise frontend."
  value       = kubernetes_ingress_v1.frontend.status[0].load_balancer[0].ingress[0].hostname
}
