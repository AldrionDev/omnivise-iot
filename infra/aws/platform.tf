data "terraform_remote_state" "platform" {
  backend = "remote"

  config = {
    organization = "gabor-toth-personalprojects"

    workspaces = {
      name = "omnivise-iot-aws-platform"
    }
  }
}
