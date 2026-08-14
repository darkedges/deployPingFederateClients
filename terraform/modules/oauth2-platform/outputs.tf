output "catalog_ids" {
  description = "Non-sensitive stable IDs; applications resolve these from the trusted YAML catalog."
  value = {
    access_token_managers = { for key, resource in pingfederate_oauth_access_token_manager.this : key => resource.manager_id }
    oidc_policies         = { for key, resource in pingfederate_openid_connect_policy.this : key => resource.policy_id }
    token_exchange        = { for key, resource in pingfederate_oauth_token_exchange_processor_policy.this : key => resource.policy_id }
  }
}
