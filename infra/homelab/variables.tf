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

variable "ingress_host" {
  type        = string
  description = "Canonical homelab LAN hostname Traefik matches for OmniVise IoT. Plain HTTP; homelab DNS resolves it to the Traefik 'web' entrypoint. Not an application concern beyond routing."
  default     = "omnivise-iot.homelab.home.arpa"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.ingress_host))
    error_message = "ingress_host must be a syntactically valid lowercase DNS hostname: RFC 1123 labels (a-z, 0-9, hyphen; no leading/trailing hyphen), at least two dot-separated labels, no uppercase, no trailing dot."
  }

  validation {
    condition     = length(var.ingress_host) <= 253
    error_message = "ingress_host must not exceed 253 characters."
  }
}

variable "traefik_entrypoint" {
  type        = string
  description = "Name of the Traefik static entrypoint that serves OmniVise IoT on the homelab LAN. Plain HTTP 'web' entrypoint only; no TLS, no websecure."
  default     = "web"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.traefik_entrypoint))
    error_message = "traefik_entrypoint must be a non-empty Traefik entrypoint name (letters, digits, hyphen, underscore)."
  }
}
