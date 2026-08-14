terraform {
  required_version = ">= 1.9.8, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.51.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "vault" {
  address = var.vault_address
}
