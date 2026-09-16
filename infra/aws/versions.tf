terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.1"
    }
  }

  cloud {
    organization = "gabor-toth-personalprojects"

    workspaces {
      name = "omnivise-iot-aws-app"
    }
  }
}
