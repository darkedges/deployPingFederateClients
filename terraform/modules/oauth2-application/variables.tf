variable "client" {
  description = "Validated and environment-rendered OAuth2 client object."
  type        = any
}

variable "catalog" {
  description = "Validated platform catalog."
  type        = any
}

variable "client_secret" {
  description = "Client secret retrieved from the derived Vault path. Never place this value in YAML."
  type        = string
  sensitive   = true
  default     = null
}
