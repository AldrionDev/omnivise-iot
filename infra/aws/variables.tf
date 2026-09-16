variable "backend_image_ref" {
  type        = string
  description = "Exact-SHA GHCR backend image reference for the AWS application deployment."

  validation {
    condition = can(regex(
      "^ghcr\\.io/aldriondev/omnivise-iot-backend:[0-9a-f]{40}$",
      var.backend_image_ref
    ))
    error_message = "backend_image_ref must be ghcr.io/aldriondev/omnivise-iot-backend:<40-char lowercase Git SHA>."
  }
}

variable "frontend_image_ref" {
  type        = string
  description = "Exact-SHA GHCR frontend image reference for the AWS application deployment."

  validation {
    condition = can(regex(
      "^ghcr\\.io/aldriondev/omnivise-iot-frontend:[0-9a-f]{40}$",
      var.frontend_image_ref
    ))
    error_message = "frontend_image_ref must be ghcr.io/aldriondev/omnivise-iot-frontend:<40-char lowercase Git SHA>."
  }
}

variable "simulator_image_ref" {
  type        = string
  description = "Exact-SHA GHCR simulator image reference for the AWS application deployment."

  validation {
    condition = can(regex(
      "^ghcr\\.io/aldriondev/omnivise-iot-simulator:[0-9a-f]{40}$",
      var.simulator_image_ref
    ))
    error_message = "simulator_image_ref must be ghcr.io/aldriondev/omnivise-iot-simulator:<40-char lowercase Git SHA>."
  }
}

variable "ghcr_username" {
  type        = string
  description = "GitHub username used by the EKS workloads to authenticate to GHCR."
  sensitive   = true

  validation {
    condition     = length(trimspace(var.ghcr_username)) > 0
    error_message = "ghcr_username must not be empty."
  }
}

variable "ghcr_token" {
  type        = string
  description = "GHCR token with permission to pull the private OmniVise packages."
  sensitive   = true

  validation {
    condition     = length(trimspace(var.ghcr_token)) > 0
    error_message = "ghcr_token must not be empty."
  }
}
