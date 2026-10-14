#!/bin/sh
set -eu

log() {
  printf '[aws-report-generation] %s\n' "$*"
}

die() {
  printf '[aws-report-generation][ERROR] %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_FILE="${SCRIPT_DIR}/report_generation.py"
SUMMARIZER_FILE="${SCRIPT_DIR}/report_summarizer.py"

[ -f "$PYTHON_FILE" ] || die "Python file not found: $PYTHON_FILE"
[ -f "$SUMMARIZER_FILE" ] || die "Summarizer file not found: $SUMMARIZER_FILE"

export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
export OPENCLAW_TASK_TYPE="${OPENCLAW_TASK_TYPE:-report_generation}"
export OPENCLAW_SELECTED_SKILL="${OPENCLAW_SELECTED_SKILL:-aws-report-generation}"
export OPENCLAW_REPORT_REQUIRE_INPUT="${OPENCLAW_REPORT_REQUIRE_INPUT:-true}"
export OPENCLAW_REPORT_UPLOAD_S3="${OPENCLAW_REPORT_UPLOAD_S3:-false}"
export OPENCLAW_REPORT_WRITE_INDEX="${OPENCLAW_REPORT_WRITE_INDEX:-false}"
export OPENCLAW_REPORT_SUMMARY_MODE="${OPENCLAW_REPORT_SUMMARY_MODE:-auto}"
export OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS="${OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS:-120}"
export OPENCLAW_RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-/app/runtime}"
export OPENCLAW_REPORT_DIR="${OPENCLAW_REPORT_DIR:-${OPENCLAW_RUNTIME_DIR}/reports}"
export OPENCLAW_REPORT_PROMPT_PATH="${OPENCLAW_REPORT_PROMPT_PATH:-/app/prompts/report_generation_prompt.txt}"

log "Starting report generation"
log "AWS_REGION=${AWS_REGION}"
log "OPENCLAW_TASK_TYPE=${OPENCLAW_TASK_TYPE}"
log "OPENCLAW_SELECTED_SKILL=${OPENCLAW_SELECTED_SKILL}"
log "OPENCLAW_SOURCE_TASK_TYPE=${OPENCLAW_SOURCE_TASK_TYPE:-unknown}"
log "OPENCLAW_SOURCE_SKILL=${OPENCLAW_SOURCE_SKILL:-unknown}"
log "OPENCLAW_REPORT_REQUIRE_INPUT=${OPENCLAW_REPORT_REQUIRE_INPUT}"
log "OPENCLAW_REPORT_UPLOAD_S3=${OPENCLAW_REPORT_UPLOAD_S3}"
log "OPENCLAW_REPORT_WRITE_INDEX=${OPENCLAW_REPORT_WRITE_INDEX}"
log "OPENCLAW_REPORT_SUMMARY_MODE=${OPENCLAW_REPORT_SUMMARY_MODE}"
log "OPENCLAW_REPORT_DIR=${OPENCLAW_REPORT_DIR}"

if [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
  log "ECS credentials relative URI detected"
elif [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
  log "ECS credentials full URI detected"
else
  log "No ECS credentials URI detected. boto3 will use the default credential chain."
fi

if [ -n "${OPENCLAW_REPORT_INPUT_JSON:-}" ]; then
  log "Report input detected from OPENCLAW_REPORT_INPUT_JSON"
elif [ -n "${OPENCLAW_REPORT_INPUT_FILE:-}" ]; then
  log "Report input file detected: ${OPENCLAW_REPORT_INPUT_FILE}"
else
  log "No explicit report input detected; EFS aggregation may be used"
fi

if [ "$OPENCLAW_REPORT_UPLOAD_S3" = "true" ] || [ "$OPENCLAW_REPORT_UPLOAD_S3" = "1" ]; then
  [ -n "${S3_REPORT_BUCKET:-}" ] || die "OPENCLAW_REPORT_UPLOAD_S3=true but S3_REPORT_BUCKET is empty"
fi

if [ "$OPENCLAW_REPORT_WRITE_INDEX" = "true" ] || [ "$OPENCLAW_REPORT_WRITE_INDEX" = "1" ]; then
  [ -n "${DYNAMODB_REPORTS_TABLE:-}" ] || die "OPENCLAW_REPORT_WRITE_INDEX=true but DYNAMODB_REPORTS_TABLE is empty"
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
  log "Result output was not valid JSON; caller will use generic report failure metadata"
fi

exit "$SKILL_EXIT_CODE"
