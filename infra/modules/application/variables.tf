variable "namespace" {
  type        = string
  description = "Name of the existing, platform-owned Kubernetes namespace OmniVise application resources deploy into."

  validation {
    condition     = length(trimspace(var.namespace)) > 0
    error_message = "namespace must not be empty."
  }
}

variable "backend_image_ref" {
  type        = string
  description = "Immutable backend container image reference (digest form or an immutable tag). No default."
}

variable "frontend_image_ref" {
  type        = string
  description = "Immutable frontend container image reference. No default."
}

variable "simulator_image_ref" {
  type        = string
  description = "Immutable simulator container image reference. No default."
}
