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

variable "mongodb_image" {
  type        = string
  default     = "mongo:7.0"
  description = "MongoDB server image reference. Must bundle a mongosh client whose major version matches the MongoDB server major version, because probes and the bootstrap Job invoke mongosh from this same image."

  validation {
    condition     = length(trimspace(var.mongodb_image)) > 0
    error_message = "mongodb_image must not be empty."
  }
}

variable "mongodb_replica_set_name" {
  type        = string
  default     = "rs0"
  description = "MongoDB replica-set name passed to mongod --replSet and used by the bootstrap Job. Supplied by the environment root."

  validation {
    condition     = length(trimspace(var.mongodb_replica_set_name)) > 0
    error_message = "mongodb_replica_set_name must not be empty."
  }
}

variable "mongodb_storage_class" {
  type        = string
  default     = null
  nullable    = true
  description = "StorageClass for the MongoDB data volume claim. null selects the cluster default StorageClass; the homelab root supplies \"local-path\". Supplied by the environment root, not assumed by the shared module."
}

variable "mongodb_storage_size" {
  type        = string
  description = "Persistent volume claim size for the MongoDB data volume; the homelab root supplies \"2Gi\". Supplied by the environment root, not assumed by the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_storage_size)) > 0
    error_message = "mongodb_storage_size must not be empty."
  }
}

variable "mongodb_cpu_request" {
  type        = string
  description = "CPU request for the MongoDB container. Part of the MongoDB container resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_cpu_request)) > 0
    error_message = "mongodb_cpu_request must not be empty."
  }
}

variable "mongodb_cpu_limit" {
  type        = string
  description = "CPU limit for the MongoDB container. Part of the MongoDB container resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_cpu_limit)) > 0
    error_message = "mongodb_cpu_limit must not be empty."
  }
}

variable "mongodb_memory_request" {
  type        = string
  description = "Memory request for the MongoDB container. Part of the MongoDB container resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_memory_request)) > 0
    error_message = "mongodb_memory_request must not be empty."
  }
}

variable "mongodb_memory_limit" {
  type        = string
  description = "Memory limit for the MongoDB container. Part of the MongoDB container resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_memory_limit)) > 0
    error_message = "mongodb_memory_limit must not be empty."
  }
}

variable "mongodb_bootstrap_cpu_request" {
  type        = string
  description = "CPU request for the replica-set bootstrap Job container. Part of the bootstrap Job resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_bootstrap_cpu_request)) > 0
    error_message = "mongodb_bootstrap_cpu_request must not be empty."
  }
}

variable "mongodb_bootstrap_cpu_limit" {
  type        = string
  description = "CPU limit for the replica-set bootstrap Job container. Part of the bootstrap Job resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_bootstrap_cpu_limit)) > 0
    error_message = "mongodb_bootstrap_cpu_limit must not be empty."
  }
}

variable "mongodb_bootstrap_memory_request" {
  type        = string
  description = "Memory request for the replica-set bootstrap Job container. Part of the bootstrap Job resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_bootstrap_memory_request)) > 0
    error_message = "mongodb_bootstrap_memory_request must not be empty."
  }
}

variable "mongodb_bootstrap_memory_limit" {
  type        = string
  description = "Memory limit for the replica-set bootstrap Job container. Part of the bootstrap Job resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_bootstrap_memory_limit)) > 0
    error_message = "mongodb_bootstrap_memory_limit must not be empty."
  }
}

# Backend application container resource budget (environment root supplies homelab values).

variable "backend_cpu_request" {
  type        = string
  description = "CPU request for the backend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.backend_cpu_request)) > 0
    error_message = "backend_cpu_request must not be empty."
  }
}

variable "backend_cpu_limit" {
  type        = string
  description = "CPU limit for the backend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.backend_cpu_limit)) > 0
    error_message = "backend_cpu_limit must not be empty."
  }
}

variable "backend_memory_request" {
  type        = string
  description = "Memory request for the backend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.backend_memory_request)) > 0
    error_message = "backend_memory_request must not be empty."
  }
}

variable "backend_memory_limit" {
  type        = string
  description = "Memory limit for the backend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.backend_memory_limit)) > 0
    error_message = "backend_memory_limit must not be empty."
  }
}

# Frontend application container resource budget.

variable "frontend_cpu_request" {
  type        = string
  description = "CPU request for the frontend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.frontend_cpu_request)) > 0
    error_message = "frontend_cpu_request must not be empty."
  }
}

variable "frontend_cpu_limit" {
  type        = string
  description = "CPU limit for the frontend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.frontend_cpu_limit)) > 0
    error_message = "frontend_cpu_limit must not be empty."
  }
}

variable "frontend_memory_request" {
  type        = string
  description = "Memory request for the frontend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.frontend_memory_request)) > 0
    error_message = "frontend_memory_request must not be empty."
  }
}

variable "frontend_memory_limit" {
  type        = string
  description = "Memory limit for the frontend container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.frontend_memory_limit)) > 0
    error_message = "frontend_memory_limit must not be empty."
  }
}

# Sensor simulator application container resource budget.

variable "simulator_cpu_request" {
  type        = string
  description = "CPU request for the sensor simulator container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.simulator_cpu_request)) > 0
    error_message = "simulator_cpu_request must not be empty."
  }
}

variable "simulator_cpu_limit" {
  type        = string
  description = "CPU limit for the sensor simulator container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.simulator_cpu_limit)) > 0
    error_message = "simulator_cpu_limit must not be empty."
  }
}

variable "simulator_memory_request" {
  type        = string
  description = "Memory request for the sensor simulator container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.simulator_memory_request)) > 0
    error_message = "simulator_memory_request must not be empty."
  }
}

variable "simulator_memory_limit" {
  type        = string
  description = "Memory limit for the sensor simulator container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.simulator_memory_limit)) > 0
    error_message = "simulator_memory_limit must not be empty."
  }
}

# MongoDB PRIMARY-wait init container budget (shared by the backend and simulator pods).

variable "mongodb_wait_cpu_request" {
  type        = string
  description = "CPU request for the MongoDB PRIMARY-wait init container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_wait_cpu_request)) > 0
    error_message = "mongodb_wait_cpu_request must not be empty."
  }
}

variable "mongodb_wait_cpu_limit" {
  type        = string
  description = "CPU limit for the MongoDB PRIMARY-wait init container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_wait_cpu_limit)) > 0
    error_message = "mongodb_wait_cpu_limit must not be empty."
  }
}

variable "mongodb_wait_memory_request" {
  type        = string
  description = "Memory request for the MongoDB PRIMARY-wait init container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_wait_memory_request)) > 0
    error_message = "mongodb_wait_memory_request must not be empty."
  }
}

variable "mongodb_wait_memory_limit" {
  type        = string
  description = "Memory limit for the MongoDB PRIMARY-wait init container. Part of the workload resource budget supplied by the environment root, not baked into the shared module."

  validation {
    condition     = length(trimspace(var.mongodb_wait_memory_limit)) > 0
    error_message = "mongodb_wait_memory_limit must not be empty."
  }
}
