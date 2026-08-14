terraform {
  required_version = "= 1.15.8"
  required_providers {
    pingfederate = {
      source  = "pingidentity/pingfederate"
      version = "= 1.8.1"
    }
  }
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "pingfederate" {}
