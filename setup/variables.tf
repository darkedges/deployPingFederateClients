variable "aws_region" {
  type        = string
  description = "AWS region for state infrastructure."
  default     = "ap-southeast-2"
}

variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name."
}

variable "github_repository" {
  type        = string
  description = "GitHub repository in owner/name form."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use owner/name format."
  }
}

variable "pingfederate_hosts" {
  type        = map(string)
  description = "PingFederate Admin API hostname for each deployment environment, without a URL scheme."
  validation {
    condition = (
      toset(keys(var.pingfederate_hosts)) == toset(["development", "staging", "production"]) &&
      alltrue([for host in values(var.pingfederate_hosts) : can(regex("^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$", host))])
    )
    error_message = "pingfederate_hosts must contain development, staging, and production hostnames without https:// or paths."
  }
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Existing GitHub Actions IAM OIDC provider ARN; leave null to create it."
  default     = null
}

variable "vault_address" {
  type        = string
  description = "HTTPS address of an initialized and unsealed Vault cluster."
  validation {
    condition     = startswith(var.vault_address, "https://")
    error_message = "vault_address must use HTTPS."
  }
}

variable "vault_jwt_path" {
  type        = string
  description = "Vault path at which to mount GitHub JWT authentication."
  default     = "jwt"
}

variable "manage_vault_jwt_backend" {
  type        = bool
  description = "Create and configure the Vault JWT auth backend. Leave false when the path already exists."
  default     = false
}

variable "manage_kv_mount" {
  type        = bool
  description = "Create the kv-v2 mount. Set false when kv already exists."
  default     = false
}

variable "pingfederate_admin_credentials" {
  type = map(object({
    username = string
    password = string
  }))
  description = "Optional initial administrator credentials keyed by environment. Prefer writing these out of band."
  sensitive   = true
  default     = {}
  validation {
    condition     = alltrue([for environment in keys(var.pingfederate_admin_credentials) : contains(["development", "staging", "production"], environment)])
    error_message = "Credential keys must be development, staging, or production."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional AWS resource tags."
  default     = {}
}
