terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62.0"
    }
  }

  cloud {
    workspaces {
      name = "omnivise-iot-aws-platform"
    }
  }
}
