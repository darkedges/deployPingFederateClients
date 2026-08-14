locals {
  raw_client = yamldecode(file(var.config_file))
  catalog    = yamldecode(file(var.platform_catalog_file))
  base_spec  = { for key, value in local.raw_client.spec : key => value if key != "environments" }
  spec       = merge(local.base_spec, try(local.raw_client.spec.environments[var.environment], {}))
  client = {
    metadata  = local.raw_client.metadata
    lifecycle = local.raw_client.lifecycle
    spec      = local.spec
    clientId  = try(local.spec.clientId, "${local.raw_client.metadata.organisation}-${local.raw_client.metadata.application}")
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
