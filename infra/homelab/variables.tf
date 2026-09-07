variable "backend_image_ref" {
  type        = string
  description = "Immutable backend container image reference. Required; no default."

  validation {
    condition     = length(trimspace(var.backend_image_ref)) > 0
    error_message = "backend_image_ref must not be empty."
  }

  validation {
    condition     = !endswith(var.backend_image_ref, ":latest")
    error_message = "backend_image_ref must be an immutable reference, not a ':latest' tag."
  }
}

variable "frontend_image_ref" {
  type        = string
  description = "Immutable frontend container image reference. Required; no default."

  validation {
    condition     = length(trimspace(var.frontend_image_ref)) > 0
    error_message = "frontend_image_ref must not be empty."
  }

  validation {
    condition     = !endswith(var.frontend_image_ref, ":latest")
    error_message = "frontend_image_ref must be an immutable reference, not a ':latest' tag."
  }
}

variable "simulator_image_ref" {
  type        = string
  description = "Immutable simulator container image reference. Required; no default."

  validation {
    condition     = length(trimspace(var.simulator_image_ref)) > 0
    error_message = "simulator_image_ref must not be empty."
  }

  validation {
    condition     = !endswith(var.simulator_image_ref, ":latest")
    error_message = "simulator_image_ref must be an immutable reference, not a ':latest' tag."
  }
}

variable "kubeconfig_path" {
  type        = string
  description = "Filesystem path to the kubeconfig used for local Terraform execution against the homelab cluster. Required; no default; not committed."

  validation {
    condition     = length(trimspace(var.kubeconfig_path)) > 0
    error_message = "kubeconfig_path must not be empty."
  }
}

variable "kubernetes_context" {
  type        = string
  description = "Kubeconfig context name selecting the homelab cluster. Required; no default; not committed."

  validation {
    condition     = length(trimspace(var.kubernetes_context)) > 0
    error_message = "kubernetes_context must not be empty."
  }
}
