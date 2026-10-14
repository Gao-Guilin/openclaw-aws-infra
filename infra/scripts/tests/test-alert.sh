#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

environment="${1:?Usage: test-alert.sh <dev|prod>}"
verify_aws_context
require_command terraform
require_command jq
terraform_init_environment "${environment}"
dir="$(env_dir "${environment}")"
evidence="$(evidence_dir "${environment}-alert")"

alarm_name="$(terraform -chdir="${dir}" output -json cloudwatch_alarm_names | jq -r .job_receiver_errors)"
jobs_table="$(terraform -chdir="${dir}" output -json dynamodb_table_names | jq -r .jobs)"
alerts_table="$(terraform -chdir="${dir}" output -json dynamodb_table_names | jq -r .alerts)"
before_alerts="$(aws dynamodb scan --table-name "${alerts_table}" --select COUNT --query Count --output text)"
trigger_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

restore_alarm() {
  aws cloudwatch set-alarm-state --alarm-name "${alarm_name}" --state-value OK --state-reason "OpenClaw controlled alert test cleanup" >/dev/null 2>&1 || true
}
trap restore_alarm EXIT HUP INT TERM

aws cloudwatch set-alarm-state \
  --alarm-name "${alarm_name}" \
  --state-value ALARM \
  --state-reason "OpenClaw controlled alert pipeline test at ${trigger_time}" >/dev/null

job_id=""
for _ in $(seq 1 90); do
  aws dynamodb scan --table-name "${jobs_table}" --consistent-read > "${evidence}/jobs-scan.json"
  job_id="$(jq -r --arg alarm "${alarm_name}" --arg trigger "${trigger_time}" '[.Items[] | select(.source.S=="cloudwatch-alarm" and .alarm_name.S==$alarm and .requested_at.S >= $trigger)] | sort_by(.requested_at.S) | last | .job_id.S // empty' "${evidence}/jobs-scan.json")"
  [[ -n "${job_id}" ]] && break
  sleep 5
done
[[ -n "${job_id}" ]] || { echo "[FAIL] No CloudWatch alarm Job was created." >&2; exit 1; }

status="$(wait_for_job_terminal "${jobs_table}" "${job_id}" 1200)"
[[ "${status}" == "SUCCEEDED" ]] || { echo "[FAIL] Alert job ${job_id} ended with ${status}." >&2; exit 1; }

for _ in $(seq 1 30); do
  after_alerts="$(aws dynamodb scan --table-name "${alerts_table}" --select COUNT --query Count --output text)"
  (( after_alerts > before_alerts )) && break
  sleep 5
done
(( after_alerts > before_alerts )) || { echo "[FAIL] Alerts table count did not increase." >&2; exit 1; }

aws dynamodb get-item --table-name "${jobs_table}" --key "{\"job_id\":{\"S\":\"${job_id}\"}}" --consistent-read > "${evidence}/job.json"
aws dynamodb scan --table-name "${alerts_table}" --consistent-read > "${evidence}/alerts-scan.json"
restore_alarm
trap - EXIT HUP INT TERM

echo "[OK] CloudWatch Alarm -> EventBridge -> Jobs -> ECS Alert -> DynamoDB/SNS path passed."
echo "JOB_ID=${job_id}"
echo "EVIDENCE_DIR=${evidence}"
