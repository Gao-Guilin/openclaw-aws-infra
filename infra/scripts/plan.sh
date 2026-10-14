#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

environment="${1:?Usage: plan.sh <dev|prod> [terraform plan arguments...]}"
shift
require_command terraform
verify_aws_context
terraform_init_environment "${environment}"
hydrate_current_environment_vars "${environment}"

dir="$(env_dir "${environment}")"
if [[ "${environment}" == "dev" ]] && terraform -chdir="${dir}" state list | grep -q 'aws_iam_openid_connect_provider.github'; then
  echo "[FAIL] dev State still owns the account-level GitHub OIDC provider." >&2
  echo "       Run ./infra/scripts/operations/migrate-github-oidc-state.sh before creating the dev Plan." >&2
  exit 1
fi
evidence="$(evidence_dir "${environment}-plan")"
plan_file="${evidence}/${environment}.tfplan"

terraform -chdir="${dir}" plan -input=false -out="${plan_file}" "$@" | tee "${evidence}/plan-console.txt"
terraform -chdir="${dir}" show -no-color "${plan_file}" > "${evidence}/plan.txt"
sha256sum "${plan_file}" > "${evidence}/plan.sha256"

echo "PLAN_FILE=${plan_file}"
echo "EVIDENCE_DIR=${evidence}"
