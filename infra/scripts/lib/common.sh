#!/usr/bin/env bash
set -Eeuo pipefail

readonly EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-000000000000}"
readonly EXPECTED_REGION="${AWS_REGION:-ap-northeast-1}"
readonly STATE_BUCKET="${TF_STATE_BUCKET:-openclaw-aws-terraform-state-000000000000-ap-northeast-1}"

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  }
}

env_dir() {
  local environment="${1:?environment is required}"
  case "${environment}" in
    dev|prod) printf '%s/infra/envs/%s\n' "$(repo_root)" "${environment}" ;;
    *) echo "[FAIL] Environment must be dev or prod." >&2; return 2 ;;
  esac
}

state_key() {
  local environment="${1:?environment is required}"
  printf 'envs/%s/terraform.tfstate\n' "${environment}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[FAIL] Required command not found: $1" >&2
    return 127
  }
}

verify_aws_context() {
  require_command aws
  local account region arn
  account="$(aws sts get-caller-identity --query Account --output text)"
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  region="$(aws configure get region || true)"
  region="${region:-${EXPECTED_REGION}}"

  [[ "${account}" == "${EXPECTED_ACCOUNT_ID}" ]] || {
    echo "[FAIL] AWS account mismatch: expected ${EXPECTED_ACCOUNT_ID}, got ${account}." >&2
    return 1
  }
  [[ "${region}" == "${EXPECTED_REGION}" ]] || {
    echo "[FAIL] AWS region mismatch: expected ${EXPECTED_REGION}, got ${region}." >&2
    return 1
  }
  echo "[OK] AWS identity: ${arn}"
  echo "[OK] AWS region: ${region}"
}

terraform_init_environment() {
  local environment="${1:?environment is required}"
  local directory
  directory="$(env_dir "${environment}")"
  terraform -chdir="${directory}" init -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=$(state_key "${environment}")" \
    -backend-config="region=${EXPECTED_REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"
}

hydrate_current_environment_vars() {
  local environment="${1:?environment is required}"
  local directory image_uri digest schedule_states
  directory="$(env_dir "${environment}")"

  if [[ -z "${TF_VAR_agent_image_digest:-}" ]]; then
    image_uri="$(terraform -chdir="${directory}" output -raw agent_image_uri 2>/dev/null || true)"
    digest="$(sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p' <<<"${image_uri}")"
    if [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      export TF_VAR_agent_image_digest="${digest}"
    fi
  fi

  : "${TF_VAR_agent_image_uri_override:=}"
  export TF_VAR_agent_image_uri_override

  if [[ -z "${TF_VAR_eventbridge_scheduler_enabled:-}" ]] && command -v jq >/dev/null 2>&1; then
    schedule_states="$(terraform -chdir="${directory}" output -json eventbridge_schedule_states 2>/dev/null || true)"
    if [[ -n "${schedule_states}" && "${schedule_states}" != "null" ]]; then
      if jq -e 'length > 0 and all(.[]; . == "ENABLED")' >/dev/null 2>&1 <<<"${schedule_states}"; then
        export TF_VAR_eventbridge_scheduler_enabled="true"
      elif jq -e 'length > 0 and all(.[]; . == "DISABLED")' >/dev/null 2>&1 <<<"${schedule_states}"; then
        export TF_VAR_eventbridge_scheduler_enabled="false"
      fi
    fi
  fi
}

evidence_dir() {
  local label="${1:?label is required}"
  local root="${OPENCLAW_EVIDENCE_ROOT:-${HOME}/openclaw-evidence}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${root}/${label}-${stamp}"
  printf '%s/%s-%s\n' "${root}" "${label}" "${stamp}"
}

wait_for_job_terminal() {
  local table_name="${1:?table name is required}"
  local job_id="${2:?job id is required}"
  local timeout_seconds="${3:-900}"
  local started status
  started="$(date +%s)"
  while true; do
    status="$(aws dynamodb get-item \
      --table-name "${table_name}" \
      --key "{\"job_id\":{\"S\":\"${job_id}\"}}" \
      --consistent-read \
      --query 'Item.status.S' \
      --output text 2>/dev/null || true)"
    case "${status}" in
      SUCCEEDED|FAILED|START_FAILED)
        printf '%s\n' "${status}"
        return 0
        ;;
    esac
    if (( $(date +%s) - started >= timeout_seconds )); then
      echo "[FAIL] Timed out waiting for job ${job_id}; last status=${status}." >&2
      return 1
    fi
    sleep 10
  done
}
