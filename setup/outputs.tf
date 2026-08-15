output "github_repository_variables" {
  description = "Values to configure as GitHub repository variables."
  value       = local.github_actions_variables
  depends_on  = [github_actions_variable.oauth2]
}

output "backend_config" {
  value = { bucket = aws_s3_bucket.terraform.id, region = var.aws_region, kms_key_id = aws_kms_key.terraform.arn, encrypt = true, use_lockfile = true }
}

output "github_oidc_trust" {
  description = "GitHub OIDC audience and subjects accepted by each AWS deployment role."
  value = {
    for environment, branch in local.environments : environment => {
      audience = "sts.amazonaws.com"
      subjects = [
        "${local.github_oidc_subject_prefix}:ref:refs/heads/${branch}",
        "${local.github_oidc_subject_prefix}:environment:${environment}",
      ]
    }
  }
}
