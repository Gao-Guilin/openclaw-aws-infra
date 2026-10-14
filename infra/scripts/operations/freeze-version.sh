#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

version="${1:-v1.0.0}"
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "[FAIL] Version must look like v1.0.0." >&2
  exit 2
}
require_command git
require_command gh
root="$(repo_root)"
cd "${root}"
[[ "$(git branch --show-current)" == "main" ]] || { echo "[FAIL] Release must be frozen from main." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "[FAIL] Tracked working tree changes exist." >&2; exit 1; }
if git rev-parse "${version}" >/dev/null 2>&1; then
  echo "[FAIL] Tag already exists: ${version}" >&2
  exit 1
fi

"${SCRIPT_DIR}/../tests/final-regression.sh" prod
read -r -p "Type FREEZE-${version} to create and push the release tag: " confirmation
[[ "${confirmation}" == "FREEZE-${version}" ]] || { echo "[FAIL] Version freeze cancelled." >&2; exit 2; }

git tag -a "${version}" -m "OpenClaw-AWS production ${version}"
git push origin "${version}"
gh release create "${version}" \
  --title "OpenClaw-AWS ${version}" \
  --notes "Production infrastructure and application entity frozen after final regression."
echo "[OK] ${version} tag and GitHub Release created."
