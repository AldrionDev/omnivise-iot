mock_provider "aws" {}
mock_provider "kubernetes" {}

override_data {
  target = data.terraform_remote_state.platform

  values = {
    outputs = {
      aws_region                         = "eu-north-1"
      cluster_name                       = "omnivise-iot"
      cluster_endpoint                   = "https://example.invalid"
      cluster_certificate_authority_data = "dGVzdA=="
    }
  }
}

run "application_contract" {
  command = plan

  variables {
    backend_image_ref   = "ghcr.io/aldriondev/omnivise-iot-backend:0123456789abcdef0123456789abcdef01234567"
    frontend_image_ref  = "ghcr.io/aldriondev/omnivise-iot-frontend:0123456789abcdef0123456789abcdef01234567"
    simulator_image_ref = "ghcr.io/aldriondev/omnivise-iot-simulator:0123456789abcdef0123456789abcdef01234567"
    ghcr_username       = "test-user"
    ghcr_token          = "test-token"
  }

  assert {
    condition     = kubernetes_namespace_v1.application.metadata[0].name == "omnivise-iot"
    error_message = "The AWS application root must own the omnivise-iot namespace."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.storage_provisioner == "ebs.csi.aws.com"
    error_message = "The AWS application StorageClass must use the Amazon EBS CSI provisioner."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.parameters["type"] == "gp3"
    error_message = "The AWS application StorageClass must provision gp3 volumes."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.volume_binding_mode == "WaitForFirstConsumer"
    error_message = "The AWS application StorageClass must use WaitForFirstConsumer volume binding."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.reclaim_policy == "Delete"
    error_message = "The AWS application StorageClass must use Delete reclaim policy."
  }

  assert {
    condition = (
      var.backend_image_ref ==
      "ghcr.io/aldriondev/omnivise-iot-backend:0123456789abcdef0123456789abcdef01234567"
    )
    error_message = "The backend image must remain an explicit exact-SHA GHCR input."
  }

  assert {
    condition = (
      var.frontend_image_ref ==
      "ghcr.io/aldriondev/omnivise-iot-frontend:0123456789abcdef0123456789abcdef01234567"
    )
    error_message = "The frontend image must remain an explicit exact-SHA GHCR input."
  }

  assert {
    condition = (
      var.simulator_image_ref ==
      "ghcr.io/aldriondev/omnivise-iot-simulator:0123456789abcdef0123456789abcdef01234567"
    )
    error_message = "The simulator image must remain an explicit exact-SHA GHCR input."
  }

  assert {
    condition     = kubernetes_secret_v1.ghcr_pull.metadata[0].name == "ghcr-pull"
    error_message = "The AWS application root must manage the GHCR image-pull Secret."
  }

  assert {
    condition     = kubernetes_secret_v1.ghcr_pull.type == "kubernetes.io/dockerconfigjson"
    error_message = "The GHCR pull Secret must use the kubernetes.io/dockerconfigjson type."
  }

  assert {
    condition     = module.application.namespace == "omnivise-iot"
    error_message = "The shared application module must target the AWS application namespace."
  }
}
