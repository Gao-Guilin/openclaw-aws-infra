#!/bin/sh
set -eu

log() {
  printf '[aws-alert-analysis] %s\n' "$*"
}

die() {
  printf '[aws-alert-analysis][ERROR] %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_FILE="${SCRIPT_DIR}/alert_analysis.py"

[ -f "$PYTHON_FILE" ] || die "Python file not found: $PYTHON_FILE"

export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
export OPENCLAW_TASK_TYPE="${OPENCLAW_TASK_TYPE:-alert_analysis}"
export OPENCLAW_SELECTED_SKILL="${OPENCLAW_SELECTED_SKILL:-aws-alert-analysis}"
export OPENCLAW_ALERT_ANALYSIS_STRICT="${OPENCLAW_ALERT_ANALYSIS_STRICT:-false}"
export OPENCLAW_ALERT_REQUIRE_PAYLOAD="${OPENCLAW_ALERT_REQUIRE_PAYLOAD:-true}"
export OPENCLAW_ALERT_PERSIST_DYNAMODB="${OPENCLAW_ALERT_PERSIST_DYNAMODB:-false}"

log "Starting alert analysis"
log "AWS_REGION=${AWS_REGION}"
log "OPENCLAW_TASK_TYPE=${OPENCLAW_TASK_TYPE}"
log "OPENCLAW_SELECTED_SKILL=${OPENCLAW_SELECTED_SKILL}"
log "OPENCLAW_ALERT_ANALYSIS_STRICT=${OPENCLAW_ALERT_ANALYSIS_STRICT}"
log "OPENCLAW_ALERT_REQUIRE_PAYLOAD=${OPENCLAW_ALERT_REQUIRE_PAYLOAD}"
log "OPENCLAW_ALERT_PERSIST_DYNAMODB=${OPENCLAW_ALERT_PERSIST_DYNAMODB}"

if [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
  log "ECS credentials relative URI detected"
elif [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
  log "ECS credentials full URI detected"
else
  log "No ECS credentials URI detected. boto3 will use the default credential chain."
fi

if [ -n "${OPENCLAW_ALERT_JSON:-}" ]; then
  log "Alert payload detected from OPENCLAW_ALERT_JSON"
elif [ -n "${OPENCLAW_ALERT_FILE:-}" ]; then
  log "Alert payload file detected: ${OPENCLAW_ALERT_FILE}"
elif [ -n "${OPENCLAW_EVENT_JSON:-}" ]; then
  log "Event payload detected from OPENCLAW_EVENT_JSON"
else
  log "No structured alert payload detected; using fallback environment fields"
fi

if [ "$OPENCLAW_ALERT_PERSIST_DYNAMODB" = "true" ] || [ "$OPENCLAW_ALERT_PERSIST_DYNAMODB" = "1" ]; then
  [ -n "${DYNAMODB_ALERTS_TABLE:-}" ] || die "OPENCLAW_ALERT_PERSIST_DYNAMODB=true but DYNAMODB_ALERTS_TABLE is empty"
fi

RESULT_FILE="${OPENCLAW_RESULT_FILE:-${OPENCLAW_RUNTIME_DIR:-/app/runtime}/results/${OPENCLAW_JOB_ID:-manual}.json}"
RESULT_TMP="${RESULT_FILE}.tmp.$$"
mkdir -p "$(dirname "$RESULT_FILE")"

cleanup_result_tmp() {
  rm -f "$RESULT_TMP"
}
trap cleanup_result_tmp EXIT HUP INT TERM

if python3 "$PYTHON_FILE" > "$RESULT_TMP"; then
  SKILL_EXIT_CODE=0
else
  SKILL_EXIT_CODE=$?
fi

cat "$RESULT_TMP"

if python3 - "$RESULT_TMP" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("r", encoding="utf-8") as handle:
    value = json.load(handle)
if not isinstance(value, dict):
    raise SystemExit("result must be a JSON object")
PY
then
  mv "$RESULT_TMP" "$RESULT_FILE"
  trap - EXIT HUP INT TERM
else
  log "Result output was not valid JSON; notification dispatcher will use generic task metadata"
fi

exit "$SKILL_EXIT_CODE"
