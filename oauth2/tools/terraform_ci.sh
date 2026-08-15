#!/usr/bin/env bash
set -euo pipefail

mode="${1:?mode is required: plan|apply|import}"
environment="${2:?environment is required}"
config_file="${3:-}"
import_id="${4:-}"

case "$environment" in
  development|staging|production) ;;
  *) echo "invalid environment: $environment" >&2; exit 2 ;;
esac

for command in aws curl jq terraform vault python3; do
  command -v "$command" >/dev/null || { echo "required command is unavailable: $command" >&2; exit 2; }
done

oidc_token() {
  local audience="$1"
  curl --fail --silent --show-error \
    --header "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" | jq -er .value
}

aws_oidc="$(oidc_token sts.amazonaws.com)"
AWS_OIDC_TOKEN="$aws_oidc" python3 - <<'PY'
import base64
import json
import os

payload = os.environ["AWS_OIDC_TOKEN"].split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
visible = {key: claims.get(key) for key in ("aud", "sub", "repository", "ref")}
print("AWS OIDC claims: " + json.dumps(visible, separators=(",", ":")))
PY
credentials="$(aws sts assume-role-with-web-identity \
  --role-arn "$AWS_ROLE_ARN" \
  --role-session-name "oauth2-${GITHUB_RUN_ID}" \
  --web-identity-token "$aws_oidc" \
  --duration-seconds 3600 \
  --query Credentials --output json)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
AWS_ACCESS_KEY_ID="$(jq -er .AccessKeyId <<<"$credentials")"
AWS_SECRET_ACCESS_KEY="$(jq -er .SecretAccessKey <<<"$credentials")"
AWS_SESSION_TOKEN="$(jq -er .SessionToken <<<"$credentials")"
unset credentials aws_oidc

vault_oidc="$(oidc_token vault)"
export VAULT_TOKEN
VAULT_TOKEN="$(vault write -field=token auth/jwt/login role="$VAULT_ROLE" jwt="$vault_oidc")"
unset vault_oidc
cleanup() {
  rm -f "${plan_file:-}" "${checksum_file:-}" /tmp/platform-secrets.json /tmp/retirement.json
  rm -rf "${pf_ca_dir:-}"
  vault token revoke -self >/dev/null 2>&1 || true
}
trap cleanup EXIT

pf_ca_dir="$(mktemp -d)"
vault read -field=certificate darkedges_idam_root/cert/ca >"$pf_ca_dir/root.pem"
vault read -field=certificate darkedges_idam_intermediate/cert/ca >"$pf_ca_dir/intermediate.pem"
chmod 0600 "$pf_ca_dir/root.pem" "$pf_ca_dir/intermediate.pem"
export PINGFEDERATE_PROVIDER_CA_CERTIFICATE_PEM_FILES="$pf_ca_dir/root.pem,$pf_ca_dir/intermediate.pem"

admin_path="pingfederate/${environment}/terraform-admin"
export PINGFEDERATE_PROVIDER_USERNAME PINGFEDERATE_PROVIDER_PASSWORD
PINGFEDERATE_PROVIDER_USERNAME="$(vault read -format=json "kv/data/$admin_path" | jq -er .data.data.username)"
PINGFEDERATE_PROVIDER_PASSWORD="$(vault read -format=json "kv/data/$admin_path" | jq -er .data.data.password)"
export PINGFEDERATE_PROVIDER_HTTPS_HOST="$PF_HTTPS_HOST"
export PINGFEDERATE_PROVIDER_INSECURE_TRUST_ALL_TLS="${PF_INSECURE_TRUST_ALL_TLS:-false}"
export PINGFEDERATE_PROVIDER_PRODUCT_VERSION=12.3
export PINGFEDERATE_TF_APPEND_USER_AGENT="GitHubActions/${GITHUB_RUN_ID}"

deleting=false
if [[ "$config_file" == deleted:* ]]; then
  deleting=true
  IFS=: read -r _ organisation application <<<"$config_file"
  stack="terraform/stacks/application-destroy"
  state_key="pingfederate/${environment}/applications/${organisation}/${application}.tfstate"
  terraform_args=()
elif [[ -z "$config_file" || "$config_file" == "platform" ]]; then
  stack="terraform/stacks/platform"
  state_key="pingfederate/${environment}/platform.tfstate"
  config_file="oauth2/platform/oauth2_platform.yaml"
  secrets_path="pingfederate/${environment}/platform-secrets"
  if vault read -format=json "kv/data/$secrets_path" >/tmp/platform-secrets.json 2>/dev/null; then
    export TF_VAR_platform_secrets
    TF_VAR_platform_secrets="$(jq -c .data.data /tmp/platform-secrets.json)"
    rm -f /tmp/platform-secrets.json
  fi
  terraform_args=(-var="catalog_file=$GITHUB_WORKSPACE/$config_file")
else
  stack="terraform/stacks/application"
  rendered="$(python3 oauth2/tools/oauth2_config.py render "$config_file" --environment "$environment")"
  organisation="$(jq -er .metadata.organisation <<<"$rendered")"
  application="$(jq -er .metadata.application <<<"$rendered")"
  state_key="pingfederate/${environment}/applications/${organisation}/${application}.tfstate"
  if [[ "$(jq -er .spec.authentication.method <<<"$rendered")" == "client_secret" ]]; then
    export TF_VAR_client_secret
    TF_VAR_client_secret="$(vault read -format=json "kv/data/oauth2/${environment}/${organisation}/${application}" | jq -er .data.data.client_secret)"
  fi
  terraform_args=(
    -var="environment=$environment"
    -var="config_file=$GITHUB_WORKSPACE/$config_file"
    -var="platform_catalog_file=$GITHUB_WORKSPACE/oauth2/platform/oauth2_platform.yaml"
  )
fi

terraform -chdir="$stack" init -input=false -reconfigure -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION" -backend-config="kms_key_id=$TF_STATE_KMS_KEY_ID" -backend-config="key=$state_key"

safe_name="$(tr '/:' '---' <<<"$state_key")"
plan_file="/tmp/${safe_name}.tfplan"
checksum_file="/tmp/${safe_name}.tfplan.sha256"
plan_object="s3://${TF_STATE_BUCKET}/plans/${GITHUB_RUN_ID}/${safe_name}.tfplan"

case "$mode" in
  plan)
    if [[ "$deleting" == true ]]; then
      marker_key="retirements/${environment}/${organisation}/${application}.json"
      disabled_at="$(aws s3api head-object --bucket "$TF_STATE_BUCKET" --key "$marker_key" --query LastModified --output text)"
      disabled_epoch="$(date -d "$disabled_at" +%s)"
      now_epoch="$(date +%s)"
      (( now_epoch - disabled_epoch >= 86400 )) || { echo "client must remain disabled for 24 hours before deletion" >&2; exit 1; }
    fi
    terraform -chdir="$stack" plan -input=false -lock-timeout=5m -out="$plan_file" "${terraform_args[@]}"
    terraform -chdir="$stack" show -no-color "$plan_file"
    aws s3 cp "$plan_file" "$plan_object" --sse aws:kms --sse-kms-key-id "$TF_STATE_KMS_KEY_ID" --no-progress
    (cd /tmp && sha256sum "${safe_name}.tfplan" >"${safe_name}.tfplan.sha256")
    aws s3 cp "$checksum_file" "${plan_object}.sha256" --sse aws:kms --sse-kms-key-id "$TF_STATE_KMS_KEY_ID" --no-progress
    cat "$checksum_file"
    ;;
  apply)
    aws s3 cp "$plan_object" "$plan_file" --no-progress
    aws s3 cp "${plan_object}.sha256" "$checksum_file" --no-progress
    (cd /tmp && sha256sum --check "${safe_name}.tfplan.sha256")
    terraform -chdir="$stack" apply -input=false -auto-approve "$plan_file"
    if [[ "$stack" == *application ]]; then
      state="$(jq -er .lifecycle.state <<<"$rendered")"
      if [[ "$state" == "disabled" ]]; then
        marker="s3://${TF_STATE_BUCKET}/retirements/${environment}/${organisation}/${application}.json"
        jq -n --arg commit "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" '{disabledAt:(now|todateiso8601),commit:$commit,runId:$run}' >/tmp/retirement.json
        aws s3 cp /tmp/retirement.json "$marker" --sse aws:kms --sse-kms-key-id "$TF_STATE_KMS_KEY_ID" --no-progress
        rm -f /tmp/retirement.json
      else
        aws s3 rm "s3://${TF_STATE_BUCKET}/retirements/${environment}/${organisation}/${application}.json" --no-progress || true
      fi
    fi
    ;;
  import)
    [[ -n "$import_id" ]] || { echo "import ID is required" >&2; exit 2; }
    [[ "$stack" == *application ]] || { echo "platform imports require an explicit resource address" >&2; exit 2; }
    terraform -chdir="$stack" import "${terraform_args[@]}" module.oauth2_client.pingfederate_oauth_client.this "$import_id"
    set +e
    terraform -chdir="$stack" plan -input=false -detailed-exitcode "${terraform_args[@]}"
    status=$?
    set -e
    [[ "$status" == "0" ]] || { echo "Imported state does not match declared configuration" >&2; exit 1; }
    ;;
  *) echo "invalid mode: $mode" >&2; exit 2 ;;
esac
