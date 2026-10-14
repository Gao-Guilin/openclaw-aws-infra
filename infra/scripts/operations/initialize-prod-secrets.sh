#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_command aws
require_command jq
verify_aws_context

# Prod owns independent Secret ARNs so dev can be destroyed later.  Values are
# copied server-side through short-lived local files with mode 600; values are
# never printed and never enter Terraform state, tfvars, Git, or Actions logs.
declare -A expected_keys=(
  [deepseek-api-key]="DEEPSEEK_API_KEY"
  [gateway-token]="OPENCLAW_GATEWAY_TOKEN"
  [quick-api-key]="QUICK_API_KEY"
  [qqbot-app-id]="QQBOT_APP_ID"
  [qqbot-client-secret]="QQBOT_CLIENT_SECRET"
)

tmpdir="$(mktemp -d)"
chmod 700 "${tmpdir}"
cleanup() {
  find "${tmpdir}" -type f -exec sh -c 'chmod 600 "$1" 2>/dev/null || true; : > "$1" 2>/dev/null || true; rm -f "$1"' _ {} \;
  rmdir "${tmpdir}" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

for suffix in deepseek-api-key gateway-token quick-api-key qqbot-app-id qqbot-client-secret; do
  source_name="openclaw-aws-dev-${suffix}"
  target_name="openclaw-aws-prod-${suffix}"
  json_key="${expected_keys[${suffix}]}"
  secret_file="${tmpdir}/${suffix}.json"
  umask 077

  aws secretsmanager describe-secret --secret-id "${source_name}" >/dev/null
  aws secretsmanager describe-secret --secret-id "${target_name}" >/dev/null
  aws secretsmanager get-secret-value \
    --secret-id "${source_name}" \
    --query SecretString \
    --output text > "${secret_file}"
  chmod 600 "${secret_file}"

  jq -e --arg key "${json_key}" \
    'type == "object" and has($key) and (.[$key] | type == "string") and (.[$key] | length > 0)' \
    "${secret_file}" >/dev/null || {
      echo "[FAIL] ${source_name} does not contain required JSON key ${json_key}." >&2
      exit 1
    }

  aws secretsmanager put-secret-value \
    --secret-id "${target_name}" \
    --secret-string "file://${secret_file}" >/dev/null
  echo "[OK] Copied fixed value: ${source_name} -> ${target_name} (${json_key})."
done

echo "[OK] All five prod Secrets were initialized without printing secret values."
