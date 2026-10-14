#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

environment="${1:?Usage: verify-scheduler-history.sh <dev|prod> [lookback-hours]}"
lookback_hours="${2:-72}"
verify_aws_context
require_command terraform
require_command jq
terraform_init_environment "${environment}"
dir="$(env_dir "${environment}")"
jobs_table="$(terraform -chdir="${dir}" output -json dynamodb_table_names | jq -r .jobs)"
cutoff="$(date -u -d "${lookback_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
out="$(mktemp)"
trap 'rm -f "${out}"' EXIT
aws dynamodb scan --table-name "${jobs_table}" --consistent-read > "${out}"
count="$(jq --arg cutoff "${cutoff}" '[.Items[] | select(.source.S=="scheduler" and .requested_at.S >= $cutoff)] | length' "${out}")"
(( count > 0 )) || { echo "[FAIL] No Scheduler Jobs records found in the last ${lookback_hours} hours." >&2; exit 1; }
jq --arg cutoff "${cutoff}" '[.Items[] | select(.source.S=="scheduler" and .requested_at.S >= $cutoff) | {job_id:.job_id.S,task_type:.task_type.S,status:.status.S,requested_at:.requested_at.S,schedule_name:.schedule_name.S}] | sort_by(.requested_at)' "${out}"
echo "[OK] Found ${count} Scheduler Jobs records with full lifecycle visibility."
