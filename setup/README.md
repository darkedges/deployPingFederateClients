# Service bootstrap

This Terraform root creates the shared prerequisites used by the deployment
workflows. It configures AWS state infrastructure and an existing initialized,
unsealed Vault cluster. It does not deploy a Vault server or PingFederate.

## Prerequisites

- Terraform 1.15.8
- AWS credentials permitted to manage S3, KMS, IAM roles, and an OIDC provider
- `VAULT_ADDR` and a `VAULT_TOKEN` allowed to manage auth methods, policies,
  mounts (when enabled), and bootstrap secrets
- An existing private Vault endpoint reachable by the deployment runners

Copy `terraform.tfvars.example` to a file outside version control, fill in the
values, and run:

```bash
terraform -chdir=setup init
terraform -chdir=setup plan -var-file=/secure/path/setup.tfvars
terraform -chdir=setup apply -var-file=/secure/path/setup.tfvars
terraform -chdir=setup output -json github_repository_variables
```

Initially use local state or a separately secured bootstrap backend. After the
bucket exists, migrate this root to a protected remote backend if desired.

The output supplies all generated GitHub variables except `OAUTH2_PF_HOSTS`,
which must be set to the private PingFederate Admin API hosts, and the review
GitHub App settings. Administrator credentials should normally be written
directly with `vault kv put`; the sensitive Terraform variable is provided only
for controlled initial bootstrapping because its values are retained in setup
state.

```bash
vault kv put kv/pingfederate/development/terraform-admin username=terraform password='...'
vault kv put kv/pingfederate/staging/terraform-admin username=terraform password='...'
vault kv put kv/pingfederate/production/terraform-admin username=terraform password='...'
```

If a GitHub OIDC provider already exists in the AWS account, pass its ARN to
`github_oidc_provider_arn`; AWS permits only one provider for a given URL in an
account. Set `manage_kv_mount=true` only when the `kv` mount does not exist.
