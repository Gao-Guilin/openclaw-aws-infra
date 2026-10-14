#!/bin/sh
set -eu

log() {
  printf '[aws-task-healthcheck] %s\n' "$*"
}

die() {
  printf '[aws-task-healthcheck][ERROR] %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_FILE="${SCRIPT_DIR}/healthcheck.py"

[ -f "$PYTHON_FILE" ] || die "Python file not found: $PYTHON_FILE"

export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"

export OPENCLAW_TASK_TYPE="${OPENCLAW_TASK_TYPE:-healthcheck}"
export OPENCLAW_SELECTED_SKILL="${OPENCLAW_SELECTED_SKILL:-aws-task-healthcheck}"
export OPENCLAW_REQUIRE_AWS="${OPENCLAW_REQUIRE_AWS:-true}"

log "Starting healthcheck"
log "AWS_REGION=${AWS_REGION}"
log "OPENCLAW_TASK_TYPE=${OPENCLAW_TASK_TYPE}"
log "OPENCLAW_SELECTED_SKILL=${OPENCLAW_SELECTED_SKILL}"
log "OPENCLAW_REQUIRE_AWS=${OPENCLAW_REQUIRE_AWS}"

if [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
  log "ECS credentials relative URI detected"
elif [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
  log "ECS credentials full URI detected"
else
  log "No ECS credentials URI detected. boto3 will use the default credential chain."
fi

exec python3 "$PYTHON_FILE"
