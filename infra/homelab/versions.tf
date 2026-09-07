terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.0"
    }
  }

  cloud {
    workspaces {
      name = "omnivise-iot-k8s"
    }
  }
}
