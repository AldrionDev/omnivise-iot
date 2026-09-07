module "application" {
  source = "../modules/application"

  namespace           = local.namespace
  backend_image_ref   = var.backend_image_ref
  frontend_image_ref  = var.frontend_image_ref
  simulator_image_ref = var.simulator_image_ref
}
