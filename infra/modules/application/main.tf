terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.0"
    }
  }
}

# The target namespace is created and owned outside this shared module by the
# environment-specific Terraform root or platform. This module only references
# it and must never create or manage it.
data "kubernetes_namespace_v1" "application" {
  metadata {
    name = var.namespace
  }
}
