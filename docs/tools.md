# Tool reference

## oauth2_config.py

The central configuration library and command-line interface.

| Command | Purpose |
| --- | --- |
| validate | Validate schemas, semantics, platform references, and naming |
| codeowners | Generate .github/CODEOWNERS from ownership.yaml |
| codeowners --check | Fail if committed ownership output is stale |
| render FILE --environment NAME | Emit the effective environment-specific client JSON |
| scaffold | Create a correctly named disabled client template |

~~~bash
python oauth2/tools/oauth2_config.py validate
python oauth2/tools/oauth2_config.py codeowners --check
python oauth2/tools/oauth2_config.py render FILE --environment development
~~~

Scaffold writes
oauth2/applications/oauth2_organisation_application.yaml and requires
lowercase organisation and application slugs.

## changed.py

Accepts a base and head Git SHA and emits compact JSON containing an
applications matrix and platform_changed flag.

- A client addition or modification selects that client.
- A disabled deletion or rename emits deleted:organisation:application.
- Deleting or renaming an enabled client fails.
- Platform catalog or platform Terraform changes select the platform.
- Application module or stack changes select every client.
- An initial push selects the platform and every client.

The script currently uses a final-tree Git diff. See
[Operations and promotion](operations.md#current-promotion-limitation).

## review_gate.py

Uses GH_APP_TOKEN and PR_NUMBER to query GitHub. It rejects forks, untrusted
authors, stale approvals, author self-approval, missing ownership, and missing
team approvals. One non-author approval is sufficient for a shared
application and identity team; distinct teams require distinct approvers.

## overlay_pr.py

Creates a privileged plan without executing PR code. Trusted base code is
checked out and only canonical application YAML or the platform catalog may be
overlaid. Forks, non-data paths, PRs of 100 or more files, and unsafe
deletions are rejected. It outputs environment, platform_changed, and targets.

## terraform_ci.sh

Usage:

~~~text
terraform_ci.sh plan|apply|import environment [target] [import-id]
~~~

The target is platform, an application YAML path, or
deleted:organisation:application. The script:

1. Verifies runner tools and installs the supplied Vault CA.
2. Exchanges GitHub OIDC tokens for AWS and Vault sessions.
3. Retrieves the PingFederate CA chain and administrator.
4. Selects an isolated stack and S3 state key.
5. Renders the environment overlay and obtains the client secret.
6. Creates and uploads a KMS-encrypted plan and checksum, or downloads,
   verifies, and applies that plan.
7. Maintains retirement markers and cleans temporary credentials and files.

Import adopts an existing client and requires a zero-change plan afterward.

## Tests

~~~bash
python -m unittest discover -s oauth2/tests -v
bash -n oauth2/tools/terraform_ci.sh
~~~

