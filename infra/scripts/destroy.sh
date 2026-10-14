#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

environment="${1:?Usage: destroy.sh <dev|prod>}"
[[ "${environment}" == "dev" ]] || {
  echo "[FAIL] This guardrail script only destroys dev. Production destruction is intentionally unsupported." >&2
  exit 2
}
require_command terraform
verify_aws_context
terraform_init_environment dev
hydrate_current_environment_vars dev

dir="$(env_dir dev)"
evidence="$(evidence_dir dev-destroy)"
terraform -chdir="${dir}" plan -destroy -input=false -out="${evidence}/dev-destroy.tfplan"
terraform -chdir="${dir}" show -no-color "${evidence}/dev-destroy.tfplan" > "${evidence}/dev-destroy-plan.txt"
echo "[INFO] Review ${evidence}/dev-destroy-plan.txt"
read -r -p "Type DESTROY-DEV to continue: " confirmation
[[ "${confirmation}" == "DESTROY-DEV" ]] || { echo "[FAIL] Destroy cancelled." >&2; exit 2; }
terraform -chdir="${dir}" apply -input=false "${evidence}/dev-destroy.tfplan"
echo "[OK] dev destroy completed."
