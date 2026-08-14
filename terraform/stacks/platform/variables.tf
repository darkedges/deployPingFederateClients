variable "catalog_file" {
  type    = string
  default = "../../../oauth2/platform/oauth2_platform.yaml"
}

variable "platform_secrets" {
  type      = map(string)
  sensitive = true
  default   = {}
}
