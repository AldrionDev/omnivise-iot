locals {
  application = "omnivise-iot"

  common_tags = {
    Project     = local.application
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  public_subnets = {
    for index, availability_zone in var.availability_zones :
    availability_zone => {
      availability_zone = availability_zone
      cidr_block        = var.public_subnet_cidrs[index]
      name              = "${local.application}-${var.environment}-public-${availability_zone}"
    }
  }

  node_group_name = "${local.application}-${var.environment}"

  gp3_storage_class_name = "omnivise-iot-gp3"
  application_namespace  = "omnivise-iot"
}
