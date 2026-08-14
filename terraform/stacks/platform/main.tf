locals {
  catalog = yamldecode(file(var.catalog_file))
}

module "oauth2_platform" {
  source  = "../../modules/oauth2-platform"
  catalog = local.catalog
  secrets = var.platform_secrets
}

output "catalog_ids" {
  value = module.oauth2_platform.catalog_ids
}
