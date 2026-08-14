locals {
  managers = {
    for manager in var.catalog.spec.accessTokenManagers : manager.key => manager
  }
  mappings = {
    for mapping in var.catalog.spec.accessTokenMappings : mapping.key => mapping
  }
  oidc_policies = {
    for policy in var.catalog.spec.oidcPolicies : policy.key => policy
  }
  exchange_policies = {
    for policy in var.catalog.spec.tokenExchangePolicies : policy.key => policy
  }
  generator_mappings = {
    for mapping in var.catalog.spec.tokenExchangeGeneratorMappings : mapping.key => mapping
  }
  manager_plugin_ids = {
    jwt       = "com.pingidentity.pf.access.token.management.plugins.JwtBearerAccessTokenManagementPlugin"
    reference = "org.sourceid.oauth20.token.plugin.impl.ReferenceBearerAccessTokenManagementPlugin"
  }
}

resource "pingfederate_oauth_access_token_manager" "this" {
  for_each = local.managers

  manager_id = each.value.managerId
  name       = each.value.name
  plugin_descriptor_ref = {
    id = local.manager_plugin_ids[each.value.profile]
  }
  attribute_contract = {
    extended_attributes = [
      for attribute in each.value.attributeContract : {
        name         = attribute.name
        multi_valued = try(attribute.multiValued, false)
      }
    ]
  }
  configuration = {
    fields = [
      for field in try(each.value.configuration.fields, []) : {
        name  = field.name
        value = field.value
      }
    ]
    sensitive_fields = [
      for field in try(each.value.configuration.sensitiveFields, []) : {
        name  = field.name
        value = var.secrets[field.secretRef]
      }
    ]
  }
  access_control_settings = {
    restrict_clients = false
  }
  selection_settings = length(try(each.value.resourceUris, [])) == 0 ? null : {
    resource_uris = each.value.resourceUris
  }
  session_validation_settings = {
    check_valid_authn_session       = false
    check_session_revocation_status = false
    update_authn_session_activity   = false
    include_session_id              = false
  }
}

resource "pingfederate_oauth_access_token_mapping" "this" {
  for_each = local.mappings

  access_token_manager_ref = {
    id = pingfederate_oauth_access_token_manager.this[each.value.accessTokenManager].id
  }
  context = {
    type = each.value.context.type
    context_ref = {
      id = each.value.context.contextRef
    }
  }
  attribute_contract_fulfillment = {
    for name, fulfillment in each.value.attributeContractFulfillment : name => {
      source = merge(
        { type = fulfillment.source.type },
        try(fulfillment.source.id, null) == null ? {} : { id = fulfillment.source.id }
      )
      value = fulfillment.value
    }
  }
}

resource "pingfederate_openid_connect_policy" "this" {
  for_each = local.oidc_policies

  policy_id = each.value.policyId
  name      = each.value.name
  access_token_manager_ref = {
    id = pingfederate_oauth_access_token_manager.this[each.value.accessTokenManager].id
  }
  attribute_contract = {
    extended_attributes = [
      for attribute in each.value.attributeContract : {
        name         = attribute.name
        multi_valued = try(attribute.multiValued, false)
      }
    ]
  }
  attribute_mapping = {
    attribute_sources = []
    attribute_contract_fulfillment = {
      for name, fulfillment in each.value.attributeContractFulfillment : name => {
        source = merge(
          { type = fulfillment.source.type },
          try(fulfillment.source.id, null) == null ? {} : { id = fulfillment.source.id }
        )
        value = fulfillment.value
      }
    }
  }
  scope_attribute_mappings         = try(each.value.scopeAttributeMappings, {})
  id_token_lifetime                = try(each.value.idTokenLifetimeMinutes, 5)
  include_user_info_in_id_token    = false
  return_id_token_on_refresh_grant = false
}

resource "pingfederate_oauth_token_exchange_processor_policy" "this" {
  for_each = local.exchange_policies

  policy_id            = each.value.policyId
  name                 = each.value.name
  actor_token_required = try(each.value.actorTokenRequired, false)
  processor_mappings = [
    for mapping in each.value.processorMappings : merge({
      subject_token_type = mapping.subjectTokenType
      subject_token_processor = {
        id = var.catalog.spec.externalReferences.tokenProcessors[mapping.subjectTokenProcessor]
      }
      attribute_contract_fulfillment = {
        for name, fulfillment in mapping.attributeContractFulfillment : name => {
          source = merge(
            { type = fulfillment.source.type },
            try(fulfillment.source.id, null) == null ? {} : { id = fulfillment.source.id }
          )
          value = fulfillment.value
        }
      }
      }, try(mapping.actorTokenProcessor, null) == null ? {} : {
      actor_token_type = mapping.actorTokenType
      actor_token_processor = {
        id = var.catalog.spec.externalReferences.tokenProcessors[mapping.actorTokenProcessor]
      }
    })
  ]
}

resource "pingfederate_oauth_token_exchange_token_generator_mapping" "this" {
  for_each = local.generator_mappings

  source_id = pingfederate_oauth_token_exchange_processor_policy.this[each.value.policy].policy_id
  target_id = var.catalog.spec.externalReferences.tokenGenerators[each.value.tokenGenerator]
  attribute_contract_fulfillment = {
    for name, fulfillment in each.value.attributeContractFulfillment : name => {
      source = merge(
        { type = fulfillment.source.type },
        try(fulfillment.source.id, null) == null ? {} : { id = fulfillment.source.id }
      )
      value = fulfillment.value
    }
  }
}
