terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.0"
    }
  }
}

# The omnivise-iot namespace is created and owned by the homelab-platform
# repository (see homelab-platform#41). This module only references it and must
# never create or manage it.
data "kubernetes_namespace_v1" "application" {
  metadata {
    name = var.namespace
  }
}
