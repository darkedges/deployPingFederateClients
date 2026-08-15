locals {
  spec    = var.client.spec
  profile = local.spec.profile
  grant_types = {
    confidential_web = ["AUTHORIZATION_CODE", "REFRESH_TOKEN"]
    public_spa       = ["AUTHORIZATION_CODE", "REFRESH_TOKEN"]
    native           = ["AUTHORIZATION_CODE", "REFRESH_TOKEN"]
    service          = ["CLIENT_CREDENTIALS"]
    device           = ["DEVICE_CODE", "REFRESH_TOKEN"]
    token_exchange   = ["TOKEN_EXCHANGE"]
  }
  authentication_method = try(local.spec.authentication.method, "none")
  client_auth = merge(
    { type = {
      none            = "NONE"
      client_secret   = "SECRET"
      private_key_jwt = "PRIVATE_KEY_JWT"
    }[local.authentication_method] },
    local.authentication_method == "client_secret" ? { secret = var.client_secret } : {}
  )
  manager_ids = {
    for manager in var.catalog.spec.accessTokenManagers : manager.key => manager.managerId
  }
  oidc_policy_ids = {
    for policy in var.catalog.spec.oidcPolicies : policy.key => policy.policyId
  }
  exchange_policy_ids = {
    for policy in var.catalog.spec.tokenExchangePolicies : policy.key => policy.policyId
  }
  advanced = try(local.spec.advanced, {})
}

resource "pingfederate_oauth_client" "this" {
  client_id   = var.client.clientId
  name        = local.spec.name
  description = try(local.spec.description, null)
  enabled     = var.client.lifecycle.state == "active"
  grant_types = local.grant_types[local.profile]

  client_auth = local.client_auth
  jwks_settings = local.authentication_method == "private_key_jwt" ? {
    jwks_url = local.spec.authentication.jwksUrl
  } : null

  default_access_token_manager_ref = {
    id = local.manager_ids[local.spec.accessTokenManager]
  }
  oidc_policy = try(local.spec.oidcPolicy, null) == null ? null : {
    policy_group = {
      id = local.oidc_policy_ids[local.spec.oidcPolicy]
    }
    # PingFederate omits empty logout collections and the provider reads them
    # back as null. Sending an empty set causes an inconsistent result after
    # apply, so normalize both absent and explicitly empty values to null.
    logout_uris               = length(try(local.spec.logoutUris, [])) == 0 ? null : local.spec.logoutUris
    post_logout_redirect_uris = length(try(local.spec.postLogoutRedirectUris, [])) == 0 ? null : local.spec.postLogoutRedirectUris
  }
  token_exchange_processor_policy_ref = try(local.spec.tokenExchangePolicy, null) == null ? null : {
    id = local.exchange_policy_ids[local.spec.tokenExchangePolicy]
  }

  redirect_uris                       = try(local.spec.redirectUris, [])
  restrict_scopes                     = true
  restricted_scopes                   = local.spec.scopes
  require_proof_key_for_code_exchange = contains(["confidential_web", "public_spa", "native"], local.profile)
  bypass_approval_page                = contains(["service", "token_exchange"], local.profile)
  refresh_rolling                     = try(local.advanced.refreshRolling, "SERVER_DEFAULT")

  client_secret_retention_period_type = try(local.advanced.clientSecretRetentionMinutes, null) == null ? "SERVER_DEFAULT" : "OVERRIDE_SERVER_DEFAULT"
  client_secret_retention_period      = try(local.advanced.clientSecretRetentionMinutes, null)

  persistent_grant_expiration_type      = try(local.advanced.persistentGrantLifetimeDays, null) == null ? "SERVER_DEFAULT" : "OVERRIDE_SERVER_DEFAULT"
  persistent_grant_expiration_time      = try(local.advanced.persistentGrantLifetimeDays, null)
  persistent_grant_expiration_time_unit = try(local.advanced.persistentGrantLifetimeDays, null) == null ? null : "DAYS"

  restricted_response_types = try(local.advanced.restrictedResponseTypes, null)

  lifecycle {
    precondition {
      condition     = local.authentication_method != "client_secret" || var.client_secret != null
      error_message = "A client_secret value must be supplied from Vault for client_secret authentication."
    }
  }
}
