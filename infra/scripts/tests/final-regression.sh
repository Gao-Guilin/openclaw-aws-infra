#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

environment="${1:-prod}"
verify_aws_context
require_command terraform
require_command jq
terraform_init_environment "${environment}"
hydrate_current_environment_vars "${environment}"
dir="$(env_dir "${environment}")"
evidence="$(evidence_dir "${environment}-final-regression")"

"${SCRIPT_DIR}/smoke-test.sh" "${environment}" | tee "${evidence}/smoke.txt"
"${SCRIPT_DIR}/test-alert.sh" "${environment}" | tee "${evidence}/alert.txt"

terraform -chdir="${dir}" output -json > "${evidence}/outputs.json"
cluster="$(terraform -chdir="${dir}" output -raw ecs_cluster_name)"

running="$(aws ecs list-tasks --cluster "${cluster}" --desired-status RUNNING --query 'length(taskArns)' --output text)"
pending="$(aws ecs list-tasks --cluster "${cluster}" --desired-status PENDING --query 'length(taskArns)' --output text)"
[[ "${running}" == "0" && "${pending}" == "0" ]] || { echo "[FAIL] ECS runtime residue exists." >&2; exit 1; }

for url in $(terraform -chdir="${dir}" output -json sqs_queue_urls | jq -r '.[]'); do
  visible="$(aws sqs get-queue-attributes --queue-url "${url}" --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text)"
  [[ "${visible}" == "0" ]] || { echo "[FAIL] Main queue residue: ${url}" >&2; exit 1; }
done
for url in $(terraform -chdir="${dir}" output -json sqs_dlq_urls | jq -r '.[]'); do
  visible="$(aws sqs get-queue-attributes --queue-url "${url}" --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text)"
  [[ "${visible}" == "0" ]] || { echo "[FAIL] DLQ residue: ${url}" >&2; exit 1; }
done

for pipe in $(terraform -chdir="${dir}" output -json eventbridge_pipe_names | jq -r '.[]'); do
  state="$(aws pipes describe-pipe --name "${pipe}" --query CurrentState --output text)"
  [[ "${state}" == "RUNNING" ]] || { echo "[FAIL] Pipe ${pipe} state=${state}." >&2; exit 1; }
done

set +e
terraform -chdir="${dir}" plan -input=false -detailed-exitcode > "${evidence}/terraform-no-drift.txt" 2>&1
plan_exit=$?
set -e
[[ ${plan_exit} -eq 0 ]] || { cat "${evidence}/terraform-no-drift.txt" >&2; exit 1; }

mapfile -t project_alarm_names < <(
  terraform -chdir="${dir}" output -json cloudwatch_alarm_names | \
    jq -r '.[] | select(type == "string" and length > 0)'
)
if (( ${#project_alarm_names[@]} > 0 )); then
  aws cloudwatch describe-alarms \
    --alarm-names "${project_alarm_names[@]}" \
    > "${evidence}/project-alarms.json"
  actual_alarms="$(jq '[.MetricAlarms[] | select(.StateValue == "ALARM")] | length' "${evidence}/project-alarms.json")"
  [[ "${actual_alarms}" == "0" ]] || {
    jq -r '.MetricAlarms[] | select(.StateValue == "ALARM") | .AlarmName' "${evidence}/project-alarms.json" >&2
    echo "[FAIL] One or more ${environment} project alarms remain in ALARM." >&2
    exit 1
  }
else
  echo '{"MetricAlarms":[]}' > "${evidence}/project-alarms.json"
fi

echo "PROJECT_FINAL_REGRESSION_PASS=1" | tee "${evidence}/result.env"
echo "ENVIRONMENT=${environment}" >> "${evidence}/result.env"
echo "EVIDENCE_DIR=${evidence}"
