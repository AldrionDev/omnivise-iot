output "namespace" {
  description = "Resolved name of the platform-owned namespace application resources target."
  value       = data.kubernetes_namespace_v1.application.metadata[0].name
}
