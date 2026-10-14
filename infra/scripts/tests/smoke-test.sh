#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

environment="${1:?Usage: smoke-test.sh <dev|prod>}"
verify_aws_context
require_command terraform
require_command curl
require_command jq
terraform_init_environment "${environment}"
dir="$(env_dir "${environment}")"

evidence="$(evidence_dir "${environment}-smoke")"
endpoint="$(terraform -chdir="${dir}" output -raw api_gateway_jobs_endpoint)"
jobs_table="$(terraform -chdir="${dir}" output -json dynamodb_table_names | jq -r .jobs)"
secret_name="$(terraform -chdir="${dir}" output -json secret_names | jq -r .quick_api_key)"

api_key="$(aws secretsmanager get-secret-value --secret-id "${secret_name}" --query SecretString --output text | jq -r .QUICK_API_KEY)"
[[ -n "${api_key}" && "${api_key}" != "null" ]] || { echo "[FAIL] Quick API key is not initialized." >&2; exit 1; }

response_file="${evidence}/healthcheck-response.json"
http_code="$(curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
  --request POST "${endpoint}" \
  --header 'content-type: application/json' \
  --header "x-api-key: ${api_key}" \
  --data '{"task_type":"healthcheck","priority":"medium","target":"aws-account"}')"
unset api_key
[[ "${http_code}" == "202" ]] || { cat "${response_file}" >&2; echo "[FAIL] API returned HTTP ${http_code}." >&2; exit 1; }
job_id="$(jq -r .job_id "${response_file}")"
[[ "${job_id}" != "null" && -n "${job_id}" ]] || { echo "[FAIL] API response did not contain job_id." >&2; exit 1; }

status="$(wait_for_job_terminal "${jobs_table}" "${job_id}" 1200)"
aws dynamodb get-item --table-name "${jobs_table}" --key "{\"job_id\":{\"S\":\"${job_id}\"}}" --consistent-read > "${evidence}/job.json"
[[ "${status}" == "SUCCEEDED" ]] || { echo "[FAIL] Smoke job ended with ${status}." >&2; exit 1; }

echo "[OK] ${environment} API -> Jobs -> Step Functions -> SQS -> Pipe -> ECS smoke test passed."
echo "JOB_ID=${job_id}"
echo "EVIDENCE_DIR=${evidence}"
