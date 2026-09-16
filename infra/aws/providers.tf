provider "aws" {
  region = data.terraform_remote_state.platform.outputs.aws_region
}

provider "kubernetes" {
  host = data.terraform_remote_state.platform.outputs.cluster_endpoint

  cluster_ca_certificate = base64decode(
    data.terraform_remote_state.platform.outputs.cluster_certificate_authority_data
  )

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"

    args = [
      "eks",
      "get-token",
      "--cluster-name",
      data.terraform_remote_state.platform.outputs.cluster_name,
      "--region",
      data.terraform_remote_state.platform.outputs.aws_region,
    ]
  }
}
