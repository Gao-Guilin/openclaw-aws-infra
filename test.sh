#!/bin/sh

echo "========== OpenClaw-Agent Static Check =========="

FAIL=0

check_file() {
  if [ -f "$1" ]; then
    echo "[OK] file exists: $1"
  else
    echo "[FAIL] missing file: $1"
    FAIL=1
  fi
}

check_dir() {
  if [ -d "$1" ]; then
    echo "[OK] dir exists: $1"
  else
    echo "[FAIL] missing dir: $1"
    FAIL=1
  fi
}

echo
echo "========== 1. Required files and directories =========="

check_dir "openclaw-agent"
check_file "openclaw-agent/Dockerfile"
check_file "openclaw-agent/requirements.txt"
check_file "openclaw-agent/entrypoint.sh"
check_file "openclaw-agent/VERSION"
check_dir "openclaw-agent/config"
check_file "openclaw-agent/config/openclaw.template.json"
check_dir "openclaw-agent/prompts"
check_dir "openclaw-agent/skills"

check_file "openclaw-agent/prompts/healthcheck_prompt.txt"
check_file "openclaw-agent/prompts/daily_inspection_prompt.txt"
check_file "openclaw-agent/prompts/cost_inspection_prompt.txt"
check_file "openclaw-agent/prompts/alert_analysis_prompt.txt"
check_file "openclaw-agent/prompts/report_generation_prompt.txt"

for skill in \
  aws-task-healthcheck \
  aws-daily-inspection \
  aws-cost-inspection \
  aws-alert-analysis \
  aws-report-generation
do
  check_dir "openclaw-agent/skills/$skill"
  check_file "openclaw-agent/skills/$skill/SKILL.md"
  check_file "openclaw-agent/skills/$skill/run_with_ecs_credentials.sh"
done

check_file "openclaw-agent/skills/aws-task-healthcheck/healthcheck.py"
check_file "openclaw-agent/skills/aws-daily-inspection/daily_inspection.py"
check_file "openclaw-agent/skills/aws-cost-inspection/cost_inspection.py"
check_file "openclaw-agent/skills/aws-alert-analysis/alert_analysis.py"
check_file "openclaw-agent/skills/aws-report-generation/report_generation.py"

echo
echo "========== 2. VERSION check =========="

if [ -s "openclaw-agent/VERSION" ]; then
  echo "[OK] VERSION is not empty: $(cat openclaw-agent/VERSION)"
else
  echo "[FAIL] VERSION is empty"
  FAIL=1
fi

echo
echo "========== 3. JSON validation =========="

if python3 -m json.tool openclaw-agent/config/openclaw.template.json >/dev/null; then
  echo "[OK] openclaw.template.json is valid JSON"
else
  echo "[FAIL] openclaw.template.json is invalid JSON"
  FAIL=1
fi

echo
echo "========== 4. Required template placeholders =========="

for placeholder in \
  "__OPENCLAW_WORKSPACE__" \
  "__OPENCLAW_GATEWAY_TOKEN__" \
  "__DEEPSEEK_API_KEY__" \
  "__QQBOT_ENABLED__" \
  "__QQBOT_APP_ID__" \
  "__QQBOT_CLIENT_SECRET__" \
  "__QQBOT_NAME__"
do
  if grep -q "$placeholder" openclaw-agent/config/openclaw.template.json; then
    echo "[OK] placeholder exists: $placeholder"
  else
    echo "[WARN] placeholder not found: $placeholder"
  fi
done

echo
echo "========== 5. Shell syntax check =========="

if sh -n openclaw-agent/entrypoint.sh; then
  echo "[OK] entrypoint.sh syntax OK"
else
  echo "[FAIL] entrypoint.sh syntax FAILED"
  FAIL=1
fi

find openclaw-agent/skills -name "run_with_ecs_credentials.sh" -print | while read -r shfile; do
  if sh -n "$shfile"; then
    echo "[OK] shell syntax OK: $shfile"
  else
    echo "[FAIL] shell syntax FAILED: $shfile"
    exit 20
  fi
done

if [ "$?" -ne 0 ]; then
  FAIL=1
fi

echo
echo "========== 6. Python syntax check =========="

find openclaw-agent/skills -name "*.py" -print | while read -r pyfile; do
  if python3 -m py_compile "$pyfile"; then
    echo "[OK] python syntax OK: $pyfile"
  else
    echo "[FAIL] python syntax FAILED: $pyfile"
    exit 30
  fi
done

if [ "$?" -ne 0 ]; then
  FAIL=1
fi

echo
echo "========== 7. Executable permission check =========="

if [ -x "openclaw-agent/entrypoint.sh" ]; then
  echo "[OK] executable: openclaw-agent/entrypoint.sh"
else
  echo "[WARN] entrypoint.sh is not executable, fixing..."
  chmod +x openclaw-agent/entrypoint.sh
fi

find openclaw-agent/skills -name "run_with_ecs_credentials.sh" -print | while read -r shfile; do
  if [ -x "$shfile" ]; then
    echo "[OK] executable: $shfile"
  else
    echo "[WARN] not executable, fixing: $shfile"
    chmod +x "$shfile"
  fi
done

find openclaw-agent/skills -name "*.py" -print | while read -r pyfile; do
  if [ -x "$pyfile" ]; then
    echo "[OK] executable: $pyfile"
  else
    echo "[WARN] not executable, fixing: $pyfile"
    chmod +x "$pyfile"
  fi
done

echo
echo "========== 8. Dockerfile COPY source check =========="

for path in \
  "openclaw-agent/requirements.txt" \
  "openclaw-agent/config" \
  "openclaw-agent/prompts" \
  "openclaw-agent/skills" \
  "openclaw-agent/VERSION" \
  "openclaw-agent/entrypoint.sh"
do
  if [ -e "$path" ]; then
    echo "[OK] Docker COPY source exists: $path"
  else
    echo "[FAIL] Docker COPY source missing: $path"
    FAIL=1
  fi
done

echo
echo "========== 9. Dockerfile basic content check =========="

for pattern in \
  "FROM node:24-bookworm-slim" \
  "OPENCLAW_VERSION=2026.6.11" \
  "npm install -g openclaw" \
  "openclaw plugins install @openclaw/deepseek-provider" \
  "ENTRYPOINT"
do
  if grep -q "$pattern" openclaw-agent/Dockerfile; then
    echo "[OK] Dockerfile contains: $pattern"
  else
    echo "[FAIL] Dockerfile missing: $pattern"
    FAIL=1
  fi
done

echo
echo "========== 10. requirements.txt check =========="

if grep -q "^boto3" openclaw-agent/requirements.txt; then
  echo "[OK] requirements.txt contains boto3"
else
  echo "[FAIL] requirements.txt missing boto3"
  FAIL=1
fi

echo
echo "========== 11. Secret safety quick check =========="

python3 - <<'PY'
import json
from pathlib import Path

path = Path("openclaw-agent/config/openclaw.template.json")
data = json.loads(path.read_text(encoding="utf-8"))

problems = []

deepseek = (
    data.get("models", {})
        .get("providers", {})
        .get("deepseek", {})
        .get("apiKey", {})
)

if isinstance(deepseek, dict):
    key_id = deepseek.get("id")
    if key_id not in ("__DEEPSEEK_API_KEY__", "DEEPSEEK_API_KEY"):
        problems.append(f"Unexpected DeepSeek apiKey id: {key_id!r}")

qqbot = data.get("channels", {}).get("qqbot", {})
if isinstance(qqbot, dict):
    client_secret = qqbot.get("clientSecret", "")
    app_id = qqbot.get("appId", "")

    if client_secret and not str(client_secret).startswith("__"):
        problems.append("QQBot clientSecret appears to be a real value, not a placeholder.")

    if app_id and not str(app_id).startswith("__"):
        problems.append("QQBot appId appears to be a real value, not a placeholder.")

if problems:
    print("[FAIL] secret safety check failed:")
    for item in problems:
        print(" -", item)
    raise SystemExit(1)

print("[OK] secret safety quick check passed")
PY

if [ "$?" -ne 0 ]; then
  FAIL=1
fi

echo
echo "========== 12. Docker availability check =========="

if docker --version; then
  echo "[OK] Docker command available"
else
  echo "[FAIL] Docker command unavailable"
  FAIL=1
fi

if docker info >/dev/null 2>&1; then
  echo "[OK] Docker daemon reachable"
else
  echo "[FAIL] Docker daemon not reachable. Start Docker first."
  FAIL=1
fi

echo
echo "========== Final Result =========="

if [ "$FAIL" -eq 0 ]; then
  echo "STATIC_CHECK_PASSED"
else
  echo "STATIC_CHECK_FAILED"
  exit 1
fi
