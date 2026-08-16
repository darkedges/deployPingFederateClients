# PingFederate OAuth2 configuration service

This directory is the declarative interface for PingFederate 12.3 OAuth2
configuration. Application teams edit one file named
`oauth2_<organisation>_<application>.yaml`; the identity platform team owns
the shared catalog and ownership registry.

## Authoring

1. Add the application team to `ownership.yaml`. This identity-owned change
   must land before an application can be scaffolded.
2. Run `oauth2-scaffold`, or copy the disabled example in `applications/`.
3. Complete all environment overlays. For a new confidential client, the
   trusted branch deployment creates its `client_secret` in Vault exactly once.
4. Run `python oauth2/tools/oauth2_config.py validate` and regenerate
   CODEOWNERS with the same tool.
5. Open a pull request to `develop`. A current-commit application-owner
   approval and a different identity-platform approver are required.

Profiles derive the permitted grants. Implicit and resource-owner-password
grants cannot be expressed. Browser/native clients require PKCE. Inline
secrets, unknown properties, insecure redirects, and wildcard redirects fail
validation.

For a single PingFederate instance, deployment automatically prefixes client
IDs with `dev-`, `stg-`, or `prod-`. Display names receive the corresponding
`DEV -`, `STG -`, or `PROD -` prefix. Keep `clientId` in YAML environment
neutral; the same definition can then progress through every environment
without client-ID collisions. The shared platform catalog is applied from
`develop` only; staging and production reuse those same access-token managers
and policies on the instance.

Create-once client-secret bootstrap uses KV-v2 CAS `0`. Deployments reuse an
existing value and cannot overwrite or delete it. PR plans, drift, import, and
rotation workflows never bootstrap missing secrets.

To retire a client, first merge `lifecycle.state: disabled`. A successful
apply writes an S3 retirement marker. Removal cannot produce a destruction
plan until that marker is at least 24 hours old.

## GitHub and runner setup

Create protected `develop`, `staging`, and `production` branches, make
`develop` the default, and allow promotion only in that order. Configure
GitHub Environments with required reviewers for staging and production.

Required repository variables:

| Variable | Purpose |
| --- | --- |
| `OAUTH2_AWS_REGION` | State bucket region |
| `OAUTH2_TF_STATE_BUCKET` | Private, versioned state bucket |
| `OAUTH2_TF_STATE_KMS_KEY_ID` | Customer-managed KMS key ARN |
| `OAUTH2_AWS_ROLE_ARNS` | JSON environment-to-OIDC-role mapping |
| `OAUTH2_VAULT_ADDR` | Internal Vault HTTPS address |
| `OAUTH2_VAULT_ROLES` | JSON environment-to-Vault-role mapping |
| `OAUTH2_PF_HOSTS` | JSON environment-to-Admin-API-host mapping |
| `OAUTH2_REVIEW_APP_ID` | Least-privilege GitHub App ID |

Store the App private key as `OAUTH2_REVIEW_APP_PRIVATE_KEY`. The App needs
pull-request read and organisation team-membership read permissions.

The Actions Runner Controller scale set must be named `arc-runner-set`, reach
the Admin API privately, trust its CA, and provide `aws`, `curl`, `jq`,
`python3`, `terraform`, and `vault`. Vault stores the dedicated PingFederate
account at `kv/pingfederate/<environment>/terraform-admin` using `username`
and `password` keys.

AWS and Vault OIDC roles must be restricted by repository, branch, and
environment claims. State access is limited to the appropriate environment
prefix. The S3 bucket must enforce TLS, SSE-KMS, versioning, and Block Public
Access. Expire objects under `plans/` after one day.

## Adoption, rotation, and drift

- `oauth2-import` imports an approved existing client and accepts it only when
  the resulting plan is empty. Existing confidential clients may need a
  coordinated Vault secret rotation.
- `oauth2-rotate` runs after an external process updates Vault. It plans,
  waits for the environment gate, and applies the saved plan.
- `oauth2-drift` plans daily and never applies. Failures update a GitHub issue.

The platform catalog manages access-token managers, access-token mappings,
OIDC policies, token-exchange processor policies, and generator mappings.
Token processors and generators remain external allowlisted references.
