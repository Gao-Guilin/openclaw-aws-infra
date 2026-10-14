#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_command terraform
verify_aws_context
root="$(repo_root)"
dev_dir="$(env_dir dev)"
shared_dir="${root}/infra/bootstrap/github-oidc"
provider_arn="arn:aws:iam::${EXPECTED_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
shared_key="bootstrap/github-oidc/terraform.tfstate"
evidence="$(evidence_dir github-oidc-migration)"

terraform_init_environment dev
terraform -chdir="${shared_dir}" init -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${shared_key}" \
  -backend-config="region=${EXPECTED_REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${provider_arn}" > "${evidence}/provider-before.json"

read -r -p "Type MIGRATE-GITHUB-OIDC to transfer Terraform ownership from dev State to shared bootstrap State: " confirmation
[[ "${confirmation}" == "MIGRATE-GITHUB-OIDC" ]] || { echo "[FAIL] OIDC State migration cancelled." >&2; exit 2; }

if ! terraform -chdir="${shared_dir}" state list | grep -qx 'aws_iam_openid_connect_provider.github'; then
  echo "[INFO] Importing the existing account-level GitHub OIDC provider into shared bootstrap State."
  terraform -chdir="${shared_dir}" import aws_iam_openid_connect_provider.github "${provider_arn}"
fi

set +e
terraform -chdir="${shared_dir}" plan -input=false -out="${evidence}/shared-oidc.tfplan" > "${evidence}/shared-oidc-plan-console.txt" 2>&1
plan_result=$?
set -e
[[ ${plan_result} -eq 0 ]] || { cat "${evidence}/shared-oidc-plan-console.txt" >&2; exit 1; }
terraform -chdir="${shared_dir}" show -no-color "${evidence}/shared-oidc.tfplan" > "${evidence}/shared-oidc-plan.txt"
sha256sum "${evidence}/shared-oidc.tfplan" > "${evidence}/shared-oidc-plan.sha256"

if ! grep -q 'No changes' "${evidence}/shared-oidc-plan.txt"; then
  echo "[INFO] The imported provider needs a shared tag/configuration update."
  echo "[INFO] Review: ${evidence}/shared-oidc-plan.txt"
  read -r -p "Type APPLY-SHARED-OIDC to apply the reviewed shared-provider Plan: " confirmation
  [[ "${confirmation}" == "APPLY-SHARED-OIDC" ]] || {
    echo "[FAIL] Shared OIDC Apply cancelled. dev State still owns the resource; rerun later." >&2
    exit 2
  }
  terraform -chdir="${shared_dir}" apply -input=false "${evidence}/shared-oidc.tfplan"
fi

removed="false"
for address in \
  'module.github_oidc.aws_iam_openid_connect_provider.github' \
  'module.github_oidc.aws_iam_openid_connect_provider.github[0]'; do
  if terraform -chdir="${dev_dir}" state list | grep -Fqx "${address}"; then
    terraform -chdir="${dev_dir}" state rm "${address}" | tee -a "${evidence}/dev-state-rm.txt"
    removed="true"
  fi
done

if terraform -chdir="${dev_dir}" state list | grep -q 'aws_iam_openid_connect_provider.github'; then
  echo "[FAIL] dev State still owns the account-level OIDC provider." >&2
  exit 1
fi
terraform -chdir="${shared_dir}" output -json > "${evidence}/shared-oidc-outputs.json"

echo "[OK] GitHub OIDC provider is owned by bootstrap/github-oidc State and shared by dev/prod."
[[ "${removed}" == "true" ]] || echo "[INFO] dev State did not contain the provider address; no removal was needed."
echo "EVIDENCE_DIR=${evidence}"
