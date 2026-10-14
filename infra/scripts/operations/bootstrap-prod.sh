#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_command terraform
require_command aws
require_command docker
require_command jq
verify_aws_context

root="$(repo_root)"
prod_dir="$(env_dir prod)"
dev_dir="$(env_dir dev)"
terraform_init_environment dev
terraform_init_environment prod

dev_repo="$(terraform -chdir="${dev_dir}" output -raw ecr_repository_url)"
dev_repo_arn="$(terraform -chdir="${dev_dir}" output -raw ecr_repository_arn)"
dev_digest="$(terraform -chdir="${dev_dir}" output -raw agent_image_uri | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p')"
[[ "${dev_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "[FAIL] Could not resolve the active dev image digest." >&2
  exit 1
}
dev_image="${dev_repo}@${dev_digest}"

evidence="$(evidence_dir prod-bootstrap)"
export TF_VAR_agent_image_uri_override="${dev_image}"
export TF_VAR_agent_image_digest="${dev_digest}"
export TF_VAR_eventbridge_scheduler_enabled="false"
export TF_VAR_additional_ecr_pull_repository_arns="[\"${dev_repo_arn}\"]"
export TF_VAR_additional_cd_ecr_repository_arns="[\"${dev_repo_arn}\"]"

# Phase 1 creates prod infrastructure while temporarily pinning ECS to the
# already-tested dev digest. No prod task is launched before Secrets are ready.
terraform -chdir="${prod_dir}" plan -input=false -out="${evidence}/prod-bootstrap.tfplan"
terraform -chdir="${prod_dir}" show -no-color "${evidence}/prod-bootstrap.tfplan" > "${evidence}/prod-bootstrap-plan.txt"
sha256sum "${evidence}/prod-bootstrap.tfplan" > "${evidence}/prod-bootstrap-plan.sha256"

echo "[INFO] Review: ${evidence}/prod-bootstrap-plan.txt"
read -r -p "Type DEPLOY-PROD-BOOTSTRAP to create prod resources: " confirmation
[[ "${confirmation}" == "DEPLOY-PROD-BOOTSTRAP" ]] || { echo "[FAIL] Bootstrap cancelled." >&2; exit 2; }
terraform -chdir="${prod_dir}" apply -input=false "${evidence}/prod-bootstrap.tfplan"

"${SCRIPT_DIR}/initialize-prod-secrets.sh"

# Build once, promote the exact digest. Docker push preserves the image content
# digest while making all layers available in the independent prod repository.
prod_repo="$(terraform -chdir="${prod_dir}" output -raw ecr_repository_url)"
prod_repo_name="$(terraform -chdir="${prod_dir}" output -raw ecr_repository_name)"
aws ecr get-login-password --region "${EXPECTED_REGION}" | \
  docker login --username AWS --password-stdin "${EXPECTED_ACCOUNT_ID}.dkr.ecr.${EXPECTED_REGION}.amazonaws.com" >/dev/null

tag="bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
docker pull "${dev_image}"
docker tag "${dev_image}" "${prod_repo}:${tag}"
docker push "${prod_repo}:${tag}"
prod_digest="$(aws ecr describe-images --repository-name "${prod_repo_name}" --image-ids "imageTag=${tag}" --query 'imageDetails[0].imageDigest' --output text)"
[[ "${prod_digest}" == "${dev_digest}" ]] || {
  echo "[FAIL] prod image digest differs from the tested dev digest." >&2
  exit 1
}

# Phase 2 removes the temporary cross-environment image URI and binds ECS to
# the prod ECR repository by the same immutable digest.
export TF_VAR_agent_image_uri_override=""
export TF_VAR_agent_image_digest="${prod_digest}"
terraform -chdir="${prod_dir}" plan -input=false -out="${evidence}/prod-activate.tfplan"
terraform -chdir="${prod_dir}" show -no-color "${evidence}/prod-activate.tfplan" > "${evidence}/prod-activate-plan.txt"
sha256sum "${evidence}/prod-activate.tfplan" > "${evidence}/prod-activate-plan.sha256"

echo "[INFO] Review: ${evidence}/prod-activate-plan.txt"
read -r -p "Type ACTIVATE-PROD-IMAGE to bind ECS to prod ECR: " confirmation
[[ "${confirmation}" == "ACTIVATE-PROD-IMAGE" ]] || { echo "[FAIL] Activation cancelled." >&2; exit 2; }
terraform -chdir="${prod_dir}" apply -input=false "${evidence}/prod-activate.tfplan"
terraform -chdir="${prod_dir}" output -json > "${evidence}/prod-outputs.json"

OPENCLAW_EVIDENCE_ROOT="${evidence}" "${SCRIPT_DIR}/../tests/smoke-test.sh" prod
OPENCLAW_EVIDENCE_ROOT="${evidence}" "${SCRIPT_DIR}/../tests/test-alert.sh" prod

# Confirm the activated configuration is stable. Scheduler remains disabled
# until the later, reviewed demo-evidence promotion.
set +e
terraform -chdir="${prod_dir}" plan -input=false -detailed-exitcode > "${evidence}/prod-no-drift.txt" 2>&1
plan_exit=$?
set -e
[[ ${plan_exit} -eq 0 ]] || {
  cat "${evidence}/prod-no-drift.txt" >&2
  echo "[FAIL] prod has pending Terraform changes after bootstrap." >&2
  exit 1
}

echo "[OK] prod bootstrap, secret initialization, immutable image promotion, smoke test, alert test, and no-drift verification passed."
echo "[ACTION] Confirm the pending SNS email subscription in operator@example.com."
echo "[ACTION] Create GitHub Environments dev, prod, and dev-destroy; protect prod with yourself as required reviewer."
echo "[ACTION] In the Quick web console, create or update the prod Connector with the prod API URL and the value stored in openclaw-aws-prod-quick-api-key."
echo "EVIDENCE_DIR=${evidence}"
