variable "catalog" {
  description = "Validated OAuth2 platform catalog."
  type        = any
}

variable "secrets" {
  description = "Platform secret aliases resolved from Vault."
  type        = map(string)
  sensitive   = true
  default     = {}
}
