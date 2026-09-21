variable "aws_region" {
  type        = string
  description = "AWS region that owns the OmniVise EKS platform."
  default     = "eu-north-1"

  validation {
    condition     = var.aws_region == "eu-north-1"
    error_message = "The initial OmniVise AWS platform milestone is restricted to eu-north-1."
  }
}

variable "environment" {
  type        = string
  description = "Environment identifier used in deterministic AWS naming and tagging."
  default     = "aws"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.environment))
    error_message = "environment must contain only lowercase letters, digits, and hyphens, and must start with a letter or digit."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the dedicated OmniVise AWS VPC."
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  type        = list(string)
  description = "Exactly two deterministic eu-north-1 Availability Zones used by the initial platform."
  default     = ["eu-north-1a", "eu-north-1b"]

  validation {
    condition = (
      length(var.availability_zones) == 2 &&
      length(distinct(var.availability_zones)) == 2 &&
      alltrue([
        for zone in var.availability_zones :
        startswith(zone, "${var.aws_region}")
      ])
    )
    error_message = "availability_zones must contain exactly two distinct zones from aws_region."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Exactly two public-subnet CIDRs, one for each configured Availability Zone."
  default     = ["10.20.0.0/20", "10.20.16.0/20"]

  validation {
    condition = (
      length(var.public_subnet_cidrs) == 2 &&
      length(distinct(var.public_subnet_cidrs)) == 2 &&
      alltrue([
        for cidr in var.public_subnet_cidrs :
        can(cidrhost(cidr, 0))
      ])
    )
    error_message = "public_subnet_cidrs must contain exactly two distinct valid IPv4 CIDR blocks."
  }
}

variable "cluster_name" {
  type        = string
  description = "Name of the Amazon EKS cluster."
  default     = "omnivise-iot"

  validation {
    condition     = can(regex("^[0-9A-Za-z][0-9A-Za-z_-]*$", var.cluster_name)) && length(var.cluster_name) <= 100
    error_message = "cluster_name must be a valid EKS cluster name of at most 100 characters."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the Amazon EKS cluster."
  default     = "1.36"

  validation {
    condition     = var.kubernetes_version == "1.36"
    error_message = "Issue #117 requires Kubernetes version 1.36."
  }
}

variable "node_instance_types" {
  type        = list(string)
  description = "EC2 instance types available to the initial EKS managed node group."
  default     = ["t3.medium"]

  validation {
    condition = (
      length(var.node_instance_types) > 0 &&
      alltrue([
        for instance_type in var.node_instance_types :
        length(trimspace(instance_type)) > 0
      ])
    )
    error_message = "node_instance_types must contain at least one non-empty EC2 instance type."
  }
}

variable "node_min_size" {
  type        = number
  description = "Minimum number of nodes in the EKS managed node group."
  default     = 1

  validation {
    condition     = var.node_min_size >= 1 && var.node_min_size == floor(var.node_min_size)
    error_message = "node_min_size must be an integer greater than or equal to 1."
  }
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of nodes in the EKS managed node group."
  default     = 1

  validation {
    condition     = var.node_desired_size >= 1 && var.node_desired_size == floor(var.node_desired_size)
    error_message = "node_desired_size must be an integer greater than or equal to 1."
  }
}

variable "node_max_size" {
  type        = number
  description = "Maximum number of nodes in the EKS managed node group."
  default     = 2

  validation {
    condition     = var.node_max_size >= 1 && var.node_max_size == floor(var.node_max_size)
    error_message = "node_max_size must be an integer greater than or equal to 1."
  }
}

variable "operator_principal_arn" {
  type        = string
  description = "Bootstrap/operator IAM role granted declarative EKS cluster-admin access. This is not the Jenkins steady-state delivery identity."
  default     = "arn:aws:iam::554422868760:role/AdminAssumeRole"

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.operator_principal_arn))
    error_message = "operator_principal_arn must be an IAM role ARN."
  }

  validation {
    condition = !contains([
      "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap",
    ], var.operator_principal_arn)
    error_message = "operator_principal_arn must not be the Jenkins delivery role or bootstrap user; Jenkins never receives the cluster-admin operator access entry."
  }
}


variable "pod_identity_agent_addon_version" {
  type        = string
  description = "Pinned EKS managed add-on version for the Pod Identity Agent."
  default     = "v1.3.10-eksbuild.3"

  validation {
    condition     = var.pod_identity_agent_addon_version == "v1.3.10-eksbuild.3"
    error_message = "Issue #126 pins the Pod Identity Agent to v1.3.10-eksbuild.3 for Kubernetes 1.36."
  }
}

variable "ebs_csi_addon_version" {
  type        = string
  description = "Pinned EKS managed add-on version for the Amazon EBS CSI Driver."
  default     = "v1.66.0-eksbuild.1"

  validation {
    condition     = var.ebs_csi_addon_version == "v1.66.0-eksbuild.1"
    error_message = "Issue #126 pins the Amazon EBS CSI Driver to v1.66.0-eksbuild.1 for Kubernetes 1.36."
  }
}
