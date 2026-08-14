mock_provider "pingfederate" {}

run "plans_platform_catalog" {
  command = plan

  variables {
    catalog_file = "../../../oauth2/platform/oauth2_platform.yaml"
  }

  assert {
    condition     = output.catalog_ids.access_token_managers.default-reference == "defaultReferenceATM"
    error_message = "The platform catalog must expose the declared stable manager ID."
  }
}
