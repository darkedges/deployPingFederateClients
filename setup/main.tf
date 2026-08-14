locals {
  environments = {
    development = "develop"
    staging     = "staging"
    production  = "production"
  }
  tags                   = merge({ Service = "pingfederate-oauth2", ManagedBy = "Terraform" }, var.tags)
  github_repository_name = split("/", var.github_repository)[1]
}

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "terraform" {
  description             = "PingFederate OAuth2 Terraform state and plans"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}

resource "aws_kms_alias" "terraform" {
  name          = "alias/pingfederate-oauth2-terraform"
  target_key_id = aws_kms_key.terraform.key_id
}

resource "aws_s3_bucket" "terraform" {
  bucket        = var.bucket_name
  force_destroy = false
  tags          = local.tags

  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "terraform" {
  bucket = aws_s3_bucket.terraform.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform" {
  bucket = aws_s3_bucket.terraform.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.terraform.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform" {
  bucket                  = aws_s3_bucket.terraform.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform" {
  depends_on = [aws_s3_bucket_versioning.terraform]
  bucket     = aws_s3_bucket.terraform.id

  rule {
    id     = "expire-plans"
    status = "Enabled"
    filter { prefix = "plans/" }
    expiration { days = 1 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
  rule {
    id     = "retain-noncurrent-state"
    status = "Enabled"
    filter { prefix = "pingfederate/" }
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

resource "aws_s3_bucket_policy" "terraform" {
  bucket = aws_s3_bucket.terraform.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*",
      Resource  = [aws_s3_bucket.terraform.arn, "${aws_s3_bucket.terraform.arn}/*"],
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.tags
}

locals {
  github_provider_arn = coalesce(var.github_oidc_provider_arn, try(aws_iam_openid_connect_provider.github[0].arn, null))
}

resource "aws_iam_role" "github" {
  for_each = local.environments
  name     = "pingfederate-oauth2-${each.key}"
  tags     = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Federated = local.github_provider_arn }, Action = "sts:AssumeRoleWithWebIdentity",
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = ["repo:${var.github_repository}:ref:refs/heads/${each.value}", "repo:${var.github_repository}:environment:${each.key}"]
      } }
    }]
  })
}

resource "aws_iam_role_policy" "github" {
  for_each = local.environments
  role     = aws_iam_role.github[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.terraform.arn,
      Condition = { StringLike = { "s3:prefix" = ["pingfederate/${each.key}/*", "plans/*", "retirements/${each.key}/*"] } } },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${aws_s3_bucket.terraform.arn}/pingfederate/${each.key}/*", "${aws_s3_bucket.terraform.arn}/plans/*", "${aws_s3_bucket.terraform.arn}/retirements/${each.key}/*"] },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = aws_kms_key.terraform.arn }
    ]
  })
}

resource "vault_jwt_auth_backend" "github" {
  count              = var.manage_vault_jwt_backend ? 1 : 0
  path               = var.vault_jwt_path
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

resource "vault_mount" "kv" {
  count       = var.manage_kv_mount ? 1 : 0
  path        = "kv"
  type        = "kv-v2"
  description = "PingFederate deployment secrets"
}

resource "vault_policy" "github" {
  for_each = local.environments
  name     = "pingfederate-oauth2-${each.key}"
  policy   = <<-EOT
    path "kv/data/pingfederate/${each.key}/*" { capabilities = ["read"] }
    path "kv/data/oauth2/${each.key}/*" { capabilities = ["read"] }
    path "darkedges_idam_root/cert/ca" { capabilities = ["read"] }
    path "darkedges_idam_intermediate/cert/ca" { capabilities = ["read"] }
  EOT
}

resource "vault_jwt_auth_backend_role" "github" {
  for_each                = local.environments
  backend                 = var.vault_jwt_path
  role_name               = "pingfederate-oauth2-${each.key}"
  role_type               = "jwt"
  bound_audiences         = ["vault"]
  user_claim              = "sub"
  token_policies          = [vault_policy.github[each.key].name]
  token_ttl               = 900
  token_max_ttl           = 1800
  token_no_default_policy = true
  bound_claims_type       = "string"
  bound_claims = {
    repository = var.github_repository
    ref        = "refs/heads/${each.value}"
  }
  depends_on = [vault_jwt_auth_backend.github]
}

resource "vault_kv_secret_v2" "pingfederate_admin" {
  for_each            = nonsensitive(toset(keys(var.pingfederate_admin_credentials)))
  mount               = "kv"
  name                = "pingfederate/${each.value}/terraform-admin"
  delete_all_versions = true
  data_json           = jsonencode(var.pingfederate_admin_credentials[each.value])
  depends_on          = [vault_mount.kv]
}

locals {
  github_actions_variables = {
    OAUTH2_AWS_REGION                = var.aws_region
    OAUTH2_TF_STATE_BUCKET           = aws_s3_bucket.terraform.id
    OAUTH2_TF_STATE_KMS_KEY_ID       = aws_kms_key.terraform.arn
    OAUTH2_AWS_ROLE_ARNS             = jsonencode({ for key, role in aws_iam_role.github : key => role.arn })
    OAUTH2_VAULT_ADDR                = var.vault_address
    OAUTH2_VAULT_ROLES               = jsonencode({ for key, role in vault_jwt_auth_backend_role.github : key => role.role_name })
    OAUTH2_PF_HOSTS                  = jsonencode(var.pingfederate_hosts)
    OAUTH2_PF_INSECURE_TRUST_ALL_TLS = tostring(var.pingfederate_insecure_trust_all_tls)
  }
}

resource "github_actions_variable" "oauth2" {
  for_each      = local.github_actions_variables
  repository    = local.github_repository_name
  variable_name = each.key
  value         = each.value
}
