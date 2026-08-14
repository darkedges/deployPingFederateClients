output "github_repository_variables" {
  description = "Values to configure as GitHub repository variables."
  value = {
    OAUTH2_AWS_REGION          = var.aws_region
    OAUTH2_TF_STATE_BUCKET     = aws_s3_bucket.terraform.id
    OAUTH2_TF_STATE_KMS_KEY_ID = aws_kms_key.terraform.arn
    OAUTH2_AWS_ROLE_ARNS       = jsonencode({ for key, role in aws_iam_role.github : key => role.arn })
    OAUTH2_VAULT_ADDR          = var.vault_address
    OAUTH2_VAULT_ROLES         = jsonencode({ for key, role in vault_jwt_auth_backend_role.github : key => role.role_name })
  }
}

output "backend_config" {
  value = { bucket = aws_s3_bucket.terraform.id, region = var.aws_region, kms_key_id = aws_kms_key.terraform.arn, encrypt = true, use_lockfile = true }
}
