# Operations and promotion

## Client lifecycle

1. Register organisation/application ownership.
2. Scaffold or author oauth2_organisation_application.yaml on a feature
   branch.
3. Keep a new client disabled until configuration is complete.
4. Validate and regenerate CODEOWNERS.
5. Open a PR to develop and obtain current-commit non-author approval.
6. Merge and verify development plan and apply.
7. Promote develop to staging, then staging to production.
8. To retire, deploy disabled, wait at least 24 hours, then delete in a
   separately reviewed change.

## Promotion

~~~text
feature branch -> develop -> staging -> production
~~~

The environment-neutral clientId is rendered with dev-, stg-, or prod- on the
single instance. Display names receive matching DEV -, STG -, and PROD -
prefixes. Wait for each deployment before promoting onward.

## Current promotion limitation

changed.py compares final Git trees before and after a push. If a client was
touched in development but its final blob is already identical on staging,
the staging merge contains no net client difference. Discovery emits an empty
application matrix and skips plan and apply even if the stg- client was never
deployed.

Rerunning does not change the diff. Until commit-range discovery or a targeted
redeploy workflow is added, make a reviewed YAML change that produces a real
target-branch diff before each required reconciliation.

The durable design is to select client files touched by commits introduced
into the target branch while evaluating deletion safety against the final
tree. That change is not yet implemented.

## Review-gate operation

- The author cannot approve their own PR.
- Approval must refer to the current head.
- One other member can approve when both roles use the same team.
- New commits require reapproval.
- A failed run is immutable. Approval creates a later review-event run; rerun
  the original failed run if a branch rule specifically requires it.

~~~bash
gh run rerun RUN_ID --failed
~~~

## Diagnosing skipped jobs

~~~bash
gh api repos/OWNER/REPOSITORY/actions/runs/RUN_ID/jobs --paginate
~~~

| Symptom | Cause |
| --- | --- |
| plan-platform skipped | No platform change, or branch is not develop |
| apply-platform skipped | Platform plan was intentionally skipped |
| plan-applications skipped | Discovery emitted an empty applications array |
| apply-applications skipped | Application plan failed, or an old workflow allowed an upstream skip to block it |
| approval missing | No approval exists for the current head SHA |

## Secrets and TLS

Trusted branch deployment may create a confidential-client secret once.
Planning, drift, and import expect it to exist. Never put secrets in YAML,
workflow inputs, variables, Terraform variable files, or runner images.

Vault TLS uses OAUTH2_VAULT_CA_PEM. PingFederate trust uses root and
intermediate certificates read from Vault PKI. Keep insecure TLS disabled
except for short, explicitly approved troubleshooting.

## Drift, import, and rotation

- Drift detection plans only; investigate its issue and plan.
- Import only when YAML is accurate and the post-import plan is empty.
- Rotate Vault using an authorized external procedure, then run oauth2-rotate
  for every affected environment.

