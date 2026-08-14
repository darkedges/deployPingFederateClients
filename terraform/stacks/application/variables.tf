variable "environment" {
  type = string
  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging, or production."
  }
}

variable "config_file" {
  type = string
}

variable "platform_catalog_file" {
  type    = string
  default = "../../../oauth2/platform/oauth2_platform.yaml"
}

variable "client_secret" {
  type      = string
  sensitive = true
  default   = null
}
