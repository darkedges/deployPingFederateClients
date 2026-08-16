mock_provider "pingfederate" {}

run "plans_disabled_example" {
  command = plan

  variables {
    environment           = "development"
    config_file           = "../../../oauth2/examples/oauth2_example_example-app.yaml"
    platform_catalog_file = "../../../oauth2/platform/oauth2_platform.yaml"
  }

  assert {
    condition     = output.client_id == "dev-example-example-app"
    error_message = "The development client ID must use the dev environment prefix."
  }
}

run "plans_staging_example" {
  command = plan

  variables {
    environment           = "staging"
    config_file           = "../../../oauth2/examples/oauth2_example_example-app.yaml"
    platform_catalog_file = "../../../oauth2/platform/oauth2_platform.yaml"
  }

  assert {
    condition     = output.client_id == "stg-example-example-app"
    error_message = "The staging client ID must use the stg environment prefix."
  }
}

run "plans_production_example" {
  command = plan

  variables {
    environment           = "production"
    config_file           = "../../../oauth2/examples/oauth2_example_example-app.yaml"
    platform_catalog_file = "../../../oauth2/platform/oauth2_platform.yaml"
  }

  assert {
    condition     = output.client_id == "prod-example-example-app"
    error_message = "The production client ID must use the prod environment prefix."
  }
}
