locals {
  raw_client = yamldecode(file(var.config_file))
  catalog    = yamldecode(file(var.platform_catalog_file))
  environment_prefixes = {
    development = "dev"
    staging     = "stg"
    production  = "prod"
  }
  environment_prefix = local.environment_prefixes[var.environment]
  base_spec          = { for key, value in local.raw_client.spec : key => value if key != "environments" }
  environment_spec   = merge(local.base_spec, try(local.raw_client.spec.environments[var.environment], {}))
  base_client_id     = try(local.environment_spec.clientId, "${local.raw_client.metadata.organisation}-${local.raw_client.metadata.application}")
  spec = merge(local.environment_spec, {
    name = "${upper(local.environment_prefix)} - ${local.environment_spec.name}"
  })
  client = {
    metadata  = local.raw_client.metadata
    lifecycle = local.raw_client.lifecycle
    spec      = local.spec
    clientId  = "${local.environment_prefix}-${local.base_client_id}"
  }
}

module "oauth2_client" {
  source        = "../../modules/oauth2-application"
  client        = local.client
  catalog       = local.catalog
  client_secret = var.client_secret
}

output "client_id" {
  value = module.oauth2_client.client_id
}
