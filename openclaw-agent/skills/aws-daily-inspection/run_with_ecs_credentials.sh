#!/bin/sh
set -eu

log() {
  printf '[aws-daily-inspection] %s\n' "$*"
}

die() {
  printf '[aws-daily-inspection][ERROR] %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_FILE="${SCRIPT_DIR}/daily_inspection.py"

[ -f "$PYTHON_FILE" ] || die "Python file not found: $PYTHON_FILE"

export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"

export OPENCLAW_TASK_TYPE="${OPENCLAW_TASK_TYPE:-daily_inspection}"
export OPENCLAW_SELECTED_SKILL="${OPENCLAW_SELECTED_SKILL:-aws-daily-inspection}"
export OPENCLAW_DAILY_INSPECTION_STRICT="${OPENCLAW_DAILY_INSPECTION_STRICT:-false}"

log "Starting daily inspection"
log "AWS_REGION=${AWS_REGION}"
log "OPENCLAW_TASK_TYPE=${OPENCLAW_TASK_TYPE}"
log "OPENCLAW_SELECTED_SKILL=${OPENCLAW_SELECTED_SKILL}"
log "OPENCLAW_DAILY_INSPECTION_STRICT=${OPENCLAW_DAILY_INSPECTION_STRICT}"

if [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
  log "ECS credentials relative URI detected"
elif [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
  log "ECS credentials full URI detected"
else
  log "No ECS credentials URI detected. boto3 will use the default credential chain."
fi

exec python3 "$PYTHON_FILE"
