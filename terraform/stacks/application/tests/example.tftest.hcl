mock_provider "pingfederate" {}

run "plans_disabled_example" {
  command = plan

  variables {
    environment           = "development"
    config_file           = "../../../oauth2/examples/oauth2_example_example-app.yaml"
    platform_catalog_file = "../../../oauth2/platform/oauth2_platform.yaml"
  }

  assert {
    condition     = output.client_id == "example-example-app"
    error_message = "The default client ID must be derived from organisation and application."
  }
}
