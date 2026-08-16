# Architecture

## Purpose

The service provides a GitOps interface for PingFederate OAuth2 clients and
shared OAuth platform objects. YAML is the source of desired configuration,
GitHub supplies review and promotion controls, Terraform reconciles resources,
Vault stores credentials, and S3 stores isolated state and saved plans.

The proof of concept uses one PingFederate instance. Environment isolation is
provided by dev-, stg-, and prod- client-ID prefixes and separate Terraform
state, Vault paths, cloud roles, and GitHub environments.

## System context

~~~mermaid
flowchart LR
  Author[Application author] -->|YAML and PR| GitHub
  Reviewer[Platform reviewer] -->|Current-commit approval| GitHub
  GitHub[GitHub and Actions] --> ARC[ARC runner set]
  ARC -->|OIDC| AWS[AWS IAM and STS]
  ARC -->|OIDC| Vault[HashiCorp Vault]
  AWS --> S3[S3 state and plans]
  Vault -->|Credentials, secrets, CAs| ARC
  ARC -->|Terraform over HTTPS| PF[PingFederate Admin API]
~~~

## Components

| Path | Responsibility |
| --- | --- |
| oauth2/applications/ | One declarative YAML file per client |
| oauth2/platform/ | Shared OAuth and OIDC platform catalog |
| oauth2/schemas/ | JSON Schema contracts |
| oauth2/ownership.yaml | Identity and application team ownership |
| oauth2/tools/ | Validation, rendering, review, discovery, and orchestration |
| terraform/modules/ | PingFederate resource implementations |
| terraform/stacks/ | Platform, application, and destroy roots |
| setup/ | AWS, Vault, GitHub variable, and trust bootstrap |
| setup/arc-runner/ | Private runner image and ARC values |
| .github/workflows/ | CI, review, deployment, and operational automation |

## Deployment sequence

~~~mermaid
sequenceDiagram
  participant U as Author
  participant G as GitHub
  participant R as ARC runner
  participant V as Vault
  participant A as AWS and S3
  participant P as PingFederate
  U->>G: Open or update PR
  G->>R: Validate and verify approval
  U->>G: Merge to environment branch
  G->>R: Discover affected targets
  R->>A: Exchange OIDC and initialize state
  R->>V: Exchange OIDC and read secrets and CAs
  R->>A: Upload checksummed plan
  R->>A: Download and verify plan
  R->>P: Apply Terraform plan
~~~

## Environment and state isolation

| Branch | Environment | Client prefix | State prefix |
| --- | --- | --- | --- |
| develop | development | dev- | pingfederate/development/ |
| staging | staging | stg- | pingfederate/staging/ |
| production | production | prod- | pingfederate/production/ |

Each application uses
pingfederate/environment/applications/organisation/application.tfstate. The
platform uses pingfederate/environment/platform.tfstate. Saved plans are
stored under plans/GitHub-run-ID and protected by a SHA-256 checksum.

## Trust and credentials

- GitHub OIDC provides short-lived AWS and Vault credentials.
- Vault stores the PingFederate administrator at
  kv/data/pingfederate/environment/terraform-admin.
- Client secrets live below
  kv/data/oauth2/environment/organisation/application and may be created once
  by trusted branch deployment using KV-v2 CAS 0.
- Vault PKI certificates are supplied to the PingFederate provider from an
  ephemeral runner directory.
- State and plans are private, versioned, TLS-only, and SSE-KMS encrypted.
- The review GitHub App requests repository contents, PR, and member read
  permissions only.

## Approval model

Approvals apply only to the current PR head. Fork PRs cannot receive a
privileged plan, and the author cannot approve their own change. When the
application and identity roles use the same team, one non-author approval
from that team satisfies the gate. Distinct teams require distinct approvers.

The review workflow checks out its implementation from the trusted base
revision, preventing a PR from weakening and executing the gate in one change.

## Safety controls

- Schema and semantic checks reject unknown fields, duplicate YAML keys,
  unsafe redirects, wildcard redirects, inline secrets, unsupported grants,
  unknown scopes, and unresolved references.
- Browser and native profiles require PKCE.
- Actions are pinned to commit SHAs.
- Apply consumes the exact checksummed plan created by the same run.
- Removal requires a disabled deployment and a 24-hour retirement period.
- Drift detection plans and raises an issue but never applies.
- Shared platform objects are changed from development only in the
  single-instance topology.

