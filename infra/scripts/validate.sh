#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_command terraform
root="$(repo_root)"
infra_dir="${root}/infra"
temp_root="$(mktemp -d)"
trap 'rm -rf "${temp_root}"' EXIT HUP INT TERM
mkdir -p "${temp_root}/plugin-cache"
export TF_PLUGIN_CACHE_DIR="${temp_root}/plugin-cache"

check_root() {
  local label="$1"
  local directory="$2"
  [[ -d "${directory}" ]] || { echo "[FAIL] Missing ${label}: ${directory}" >&2; exit 12; }
  find "${directory}" -maxdepth 1 -type f -name '*.tf' -print -quit | grep -q . || {
    echo "[FAIL] No Terraform files in ${label}: ${directory}" >&2
    exit 13
  }
  [[ -f "${directory}/.terraform.lock.hcl" ]] || {
    echo "[FAIL] Missing provider lock file in ${label}: ${directory}" >&2
    exit 14
  }
}

validate_root() {
  local label="$1"
  local directory="$2"
  local data_dir="$3"
  mkdir -p "${data_dir}"
  echo "[INFO] Validating ${label}: ${directory}"
  TF_DATA_DIR="${data_dir}" terraform -chdir="${directory}" init \
    -backend=false \
    -input=false \
    -lockfile=readonly \
    -no-color
  TF_DATA_DIR="${data_dir}" terraform -chdir="${directory}" validate -no-color
  echo "[OK] ${label} validation passed."
}

echo "========== OpenClaw-AWS Terraform Validation =========="
echo "[INFO] Repository root: ${root}"
terraform version | sed -n '1p'

terraform -chdir="${infra_dir}" fmt -check -diff -recursive

for bootstrap in remote-state github-oidc; do
  directory="${infra_dir}/bootstrap/${bootstrap}"
  check_root "bootstrap/${bootstrap}" "${directory}"
  validate_root "bootstrap/${bootstrap}" "${directory}" "${temp_root}/bootstrap-${bootstrap}"
done

for environment in dev prod; do
  directory="${infra_dir}/envs/${environment}"
  check_root "envs/${environment}" "${directory}"
  validate_root "envs/${environment}" "${directory}" "${temp_root}/env-${environment}"
done

echo "TERRAFORM_VALIDATION_PASSED"
