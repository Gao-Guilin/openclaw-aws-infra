#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

environment="${1:?Usage: deploy.sh <dev|prod> <saved-plan.tfplan>}"
plan_file="${2:?A reviewed saved Terraform plan is required.}"
[[ -f "${plan_file}" ]] || { echo "[FAIL] Plan file not found: ${plan_file}" >&2; exit 1; }

require_command terraform
verify_aws_context
terraform_init_environment "${environment}"
dir="$(env_dir "${environment}")"

if [[ "${environment}" == "prod" ]]; then
  read -r -p "Type DEPLOY-PROD to apply the reviewed plan: " confirmation
  [[ "${confirmation}" == "DEPLOY-PROD" ]] || { echo "[FAIL] Production deployment cancelled." >&2; exit 2; }
fi

terraform -chdir="${dir}" apply -input=false "${plan_file}"
terraform -chdir="${dir}" output -json > "$(dirname "${plan_file}")/${environment}-outputs.json"
echo "[OK] ${environment} apply completed."
