# Workflow reference

All workflows run on the ARC scale set named arc-runner-set. Actions are
pinned to immutable commit SHAs.

## Summary

| Workflow | Trigger | Mutates PingFederate |
| --- | --- | --- |
| oauth2-validate | Pull request or reusable call | No |
| oauth2-review-gate | PR changes and review changes | No |
| oauth2-pr-plan | Manual dispatch | No |
| oauth2-deploy | Push to develop, staging, production | Yes |
| oauth2-promotion-check | PR to staging or production | No |
| oauth2-scaffold | Manual dispatch | No; opens a draft PR |
| oauth2-drift | Daily schedule or manual dispatch | No |
| oauth2-import | Manual dispatch | Imports state only |
| oauth2-rotate | Manual dispatch | Yes |

## oauth2-validate

Runs for relevant pull requests and is called by branch deployment before
discovery. It verifies runner dependencies, YAML schema and semantics, unit
tests, reproducible CODEOWNERS, linting, Terraform formatting and validation,
mocked Terraform tests, and absence of obvious inline credentials.
Deployment discovery cannot start unless validation succeeds.

## oauth2-review-gate

Runs when a relevant PR opens, synchronizes, or reopens and whenever a review
is submitted or dismissed. It creates a least-privilege GitHub App token,
checks out the trusted base SHA, and invokes review_gate.py.

An initial run can fail before approval. Approval triggers a new
pull_request_review run. If branch rules require the original pull_request
check, rerun its failed job after approval:

~~~bash
gh run rerun RUN_ID --failed
~~~

Any new commit invalidates current-commit approval.

## oauth2-pr-plan

Manually plans an approved internal PR. It verifies approvals using trusted
code, overlays only permitted YAML, validates it, and plans selected targets.
It cannot apply, bootstrap a missing secret, or execute code from the PR.

## oauth2-deploy

Runs on relevant pushes to develop, staging, and production.

~~~mermaid
flowchart TD
  V[Validate] --> D[Discover environment and targets]
  D --> PP{Development platform changed?}
  PP -->|Yes| P1[Plan platform]
  P1 --> A1[Apply platform]
  PP -->|No| PA[Plan affected applications]
  A1 --> PA
  PA --> AA[Apply affected applications]
~~~

| Branch | Environment |
| --- | --- |
| develop | development |
| staging | staging |
| production | production |

Discovery emits a per-client matrix. Platform changes run only in
development. Application planning and apply explicitly tolerate an
intentionally skipped platform path but still require successful discovery
and application planning.

Plan and apply share a GitHub run ID. Apply retrieves and verifies the saved
plan produced by plan. GitHub environments may add approval gates.

## oauth2-promotion-check

Requires staging PRs to originate from develop and production PRs to
originate from staging. Target discovery occurs after merge in oauth2-deploy.

## oauth2-scaffold

Accepts organisation, application, display name, and profile. It generates a
disabled client and CODEOWNERS, creates a branch, and opens a draft PR.

## oauth2-drift

Runs daily at 01:17 UTC or manually. A matrix plans all three environments,
never applies, and creates or comments on one open drift issue per failed
environment.

## oauth2-import

Accepts environment, canonical application path, and existing client ID. It
is protected by the GitHub environment, constrains the path, imports isolated
application state, and requires an empty post-import plan.

## oauth2-rotate

Accepts environment and client file. An external process updates Vault first;
the workflow then plans, passes the environment gate, and applies the saved
plan.

## Required configuration

Variables: OAUTH2_AWS_REGION, OAUTH2_TF_STATE_BUCKET,
OAUTH2_TF_STATE_KMS_KEY_ID, OAUTH2_AWS_ROLE_ARNS, OAUTH2_VAULT_ADDR,
OAUTH2_VAULT_CA_PEM, OAUTH2_VAULT_ROLES, OAUTH2_PF_HOSTS,
OAUTH2_PF_INSECURE_TRUST_ALL_TLS, and OAUTH2_REVIEW_APP_ID.

The required secret is OAUTH2_REVIEW_APP_PRIVATE_KEY. JSON mappings must
contain development, staging, and production keys. See
[setup/README.md](../setup/README.md).

