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
    condition     = local.mongodb_storage_class == "omnivise-iot-gp3"
    error_message = "The AWS application root must reference the platform-owned StorageClass by its known name."
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

  assert {
    condition     = kubernetes_ingress_v1.frontend.spec[0].ingress_class_name == "alb"
    error_message = "The AWS application ingress must use the ALB ingress class."
  }

  assert {
    condition     = kubernetes_ingress_v1.frontend.metadata[0].annotations["alb.ingress.kubernetes.io/scheme"] == "internet-facing"
    error_message = "The AWS application ingress must provision an internet-facing ALB."
  }

  assert {
    condition = (
      kubernetes_ingress_v1.frontend.spec[0].rule[0].http[0].path[0].backend[0].service[0].name == "frontend" &&
      kubernetes_ingress_v1.frontend.spec[0].rule[0].http[0].path[0].backend[0].service[0].port[0].number == 80
    )
    error_message = "The AWS application ingress must route all traffic to the frontend Service on port 80."
  }

  assert {
    condition     = kubernetes_ingress_v1.frontend.metadata[0].annotations["alb.ingress.kubernetes.io/target-type"] == "ip"
    error_message = "The AWS application ingress must use ALB IP targets."
  }

  assert {
    condition     = kubernetes_ingress_v1.frontend.metadata[0].annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/"
    error_message = "The AWS application ingress health check must use the frontend root path."
  }
}
