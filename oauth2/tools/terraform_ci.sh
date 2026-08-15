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

describe_oidc() {
  local label="$1"
  local token="$2"
  OIDC_LABEL="$label" OIDC_TOKEN="$token" python3 - <<'PY'
import base64
import json
import os

def decode(segment):
    segment += "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(segment))

header_segment, payload_segment, _ = os.environ["OIDC_TOKEN"].split(".")
header = decode(header_segment)
claims = decode(payload_segment)
visible_header = {key: header.get(key) for key in ("alg", "kid")}
visible_claims = {key: claims.get(key) for key in ("iss", "aud", "sub", "repository", "ref")}
label = os.environ["OIDC_LABEL"]
print(f"{label} OIDC header: " + json.dumps(visible_header, separators=(",", ":")))
print(f"{label} OIDC claims: " + json.dumps(visible_claims, separators=(",", ":")))
PY
}

read_or_create_client_secret() {
  local secret_path="$1"
  CLIENT_SECRET_PATH="$secret_path" python3 - <<'PY'
import json
import os
import secrets
import ssl
import sys
import urllib.error
import urllib.request

url = f"{os.environ['VAULT_ADDR'].rstrip('/')}/v1/kv/data/{os.environ['CLIENT_SECRET_PATH']}"
context = ssl.create_default_context(cafile=os.environ["VAULT_CACERT"])
headers = {"X-Vault-Token": os.environ["VAULT_TOKEN"]}

def request(method, payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request_headers = headers | ({"Content-Type": "application/json"} if body else {})
    req = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    with urllib.request.urlopen(req, context=context, timeout=30) as response:
        return json.load(response)

def read_secret():
    try:
        response = request("GET")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    value = response.get("data", {}).get("data", {}).get("client_secret")
    if not isinstance(value, str) or not value:
        raise RuntimeError("Vault entry exists but does not contain a non-empty client_secret")
    return value

client_secret = read_secret()
if client_secret is None:
    if os.environ.get("ALLOW_SECRET_BOOTSTRAP", "false").lower() != "true":
        raise RuntimeError(
            "client_secret is absent; create-once bootstrap is allowed only in the trusted deployment workflow"
        )
    candidate = secrets.token_urlsafe(48)
    try:
        request("POST", {"options": {"cas": 0}, "data": {"client_secret": candidate}})
        client_secret = candidate
        print(f"Created client_secret at kv/data/{os.environ['CLIENT_SECRET_PATH']}", file=sys.stderr)
    except urllib.error.HTTPError:
        # A concurrent deployment may have won the CAS=0 create. Read its value;
        # any unrelated failure is re-raised when no value now exists.
        client_secret = read_secret()
        if client_secret is None:
            raise

print(client_secret)
PY
}

[[ -n "${VAULT_CA_PEM:-}" ]] || { echo "VAULT_CA_PEM is required to verify Vault TLS" >&2; exit 2; }
vault_ca_file="$(mktemp)"
printf '%s\n' "$VAULT_CA_PEM" >"$vault_ca_file"
chmod 0600 "$vault_ca_file"
export VAULT_CACERT="$vault_ca_file"

cleanup() {
  rm -f "${plan_file:-}" "${checksum_file:-}" "${vault_ca_file:-}" /tmp/platform-secrets.json /tmp/retirement.json
  rm -rf "${pf_ca_dir:-}"
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    vault token revoke -self >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

aws_oidc="$(oidc_token sts.amazonaws.com)"
describe_oidc AWS "$aws_oidc"
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
describe_oidc Vault "$vault_oidc"
export VAULT_TOKEN
VAULT_TOKEN="$(vault write -field=token auth/jwt/login role="$VAULT_ROLE" jwt="$vault_oidc")"
unset vault_oidc

pf_ca_dir="$(mktemp -d)"
vault read -field=certificate darkedges_idam_root/cert/ca >"$pf_ca_dir/root.pem"
vault read -field=certificate darkedges_idam_intermediate/cert/ca >"$pf_ca_dir/intermediate.pem"
chmod 0600 "$pf_ca_dir/root.pem" "$pf_ca_dir/intermediate.pem"
export PINGFEDERATE_PROVIDER_CA_CERTIFICATE_PEM_FILES="$pf_ca_dir/root.pem,$pf_ca_dir/intermediate.pem"

admin_path="pingfederate/${environment}/terraform-admin"
export PINGFEDERATE_PROVIDER_USERNAME PINGFEDERATE_PROVIDER_PASSWORD
PINGFEDERATE_PROVIDER_USERNAME="$(vault read -format=json "kv/data/$admin_path" | jq -er .data.data.username)"
PINGFEDERATE_PROVIDER_PASSWORD="$(vault read -format=json "kv/data/$admin_path" | jq -er .data.data.password)"
case "$PF_HTTPS_HOST" in
  https://*) pingfederate_https_host="$PF_HTTPS_HOST" ;;
  http://*) echo "PF_HTTPS_HOST must use HTTPS" >&2; exit 2 ;;
  *://*) echo "PF_HTTPS_HOST uses an unsupported URI scheme" >&2; exit 2 ;;
  *) pingfederate_https_host="https://${PF_HTTPS_HOST}" ;;
esac
export PINGFEDERATE_PROVIDER_HTTPS_HOST="$pingfederate_https_host"
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
    TF_VAR_client_secret="$(read_or_create_client_secret "oauth2/${environment}/${organisation}/${application}")"
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
