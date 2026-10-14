#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

environment="${1:?Usage: test-dlq-redrive.sh <dev|prod>}"
[[ "${environment}" == "dev" ]] || { echo "[FAIL] Destructive DLQ redrive exercise is restricted to dev." >&2; exit 2; }
verify_aws_context
require_command terraform
require_command jq
terraform_init_environment dev
dir="$(env_dir dev)"
pipe="$(terraform -chdir="${dir}" output -json eventbridge_pipe_names | jq -r .low)"
queue_url="$(terraform -chdir="${dir}" output -json sqs_queue_urls | jq -r .low)"
dlq_url="$(terraform -chdir="${dir}" output -json sqs_dlq_urls | jq -r .low)"
message_id="dlq-test-$(date -u +%s)"

restart_pipe() { aws pipes start-pipe --name "${pipe}" >/dev/null 2>&1 || true; }
trap restart_pipe EXIT HUP INT TERM

aws pipes stop-pipe --name "${pipe}" >/dev/null
for _ in $(seq 1 60); do
  state="$(aws pipes describe-pipe --name "${pipe}" --query CurrentState --output text)"
  [[ "${state}" == "STOPPED" ]] && break
  sleep 5
done
[[ "${state}" == "STOPPED" ]] || { echo "[FAIL] Pipe did not stop." >&2; exit 1; }

body="{\"job_id\":\"${message_id}\",\"task_type\":\"healthcheck\",\"priority\":\"low\",\"target\":\"aws-account\",\"source\":\"dlq-test\",\"requested_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"alert_json\":\"{}\"}"
aws sqs send-message --queue-url "${queue_url}" --message-body "${body}" >/dev/null

# maxReceiveCount is 3. Four explicit receives without delete force redrive.
for _ in 1 2 3 4; do
  receipt="$(aws sqs receive-message --queue-url "${queue_url}" --wait-time-seconds 1 --visibility-timeout 0 --max-number-of-messages 1 --query 'Messages[0].ReceiptHandle' --output text || true)"
  sleep 2
done

found="false"
for _ in $(seq 1 30); do
  messages="$(aws sqs receive-message --queue-url "${dlq_url}" --wait-time-seconds 2 --visibility-timeout 30 --max-number-of-messages 10 --output json)"
  if jq -e --arg id "${message_id}" '.Messages[]? | select(.Body | contains($id))' >/dev/null <<<"${messages}"; then
    receipt="$(jq -r --arg id "${message_id}" '.Messages[] | select(.Body | contains($id)) | .ReceiptHandle' <<<"${messages}" | head -1)"
    aws sqs delete-message --queue-url "${dlq_url}" --receipt-handle "${receipt}"
    found="true"
    break
  fi
  sleep 2
done
[[ "${found}" == "true" ]] || { echo "[FAIL] Test message did not reach the DLQ." >&2; exit 1; }
restart_pipe
trap - EXIT HUP INT TERM
echo "[OK] SQS maxReceiveCount -> DLQ redrive behavior passed in dev."
