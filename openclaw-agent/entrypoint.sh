#!/bin/sh
set -eu

log() {
  printf '[openclaw-agent] %s\n' "$*"
}

warn() {
  printf '[openclaw-agent][WARN] %s\n' "$*" >&2
}

job_status_flag_enabled() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on|enabled)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

job_status_update() {
  JOB_STATUS_ACTION="$1"
  shift

  if ! job_status_flag_enabled "${OPENCLAW_JOB_STATUS_ENABLED:-true}"; then
    return 0
  fi

  if [ -z "${DYNAMODB_JOBS_TABLE:-}" ] || [ -z "${OPENCLAW_JOB_ID:-}" ]; then
    warn "Jobs lifecycle update skipped because table name or job id is missing"
    return 0
  fi

  JOB_STATUS_HELPER="${OPENCLAW_JOB_STATUS_HELPER:-/app/skills/_shared/job_status_store.py}"

  if [ ! -f "$JOB_STATUS_HELPER" ]; then
    warn "Jobs lifecycle helper not found: $JOB_STATUS_HELPER"
    return 2
  fi

  python3 "$JOB_STATUS_HELPER" "$JOB_STATUS_ACTION" \
    --table-name "$DYNAMODB_JOBS_TABLE" \
    --job-id "$OPENCLAW_JOB_ID" \
    --region "${AWS_REGION:-ap-northeast-1}" \
    "$@"
}

mark_job_failed_best_effort() {
  JOB_FAILURE_MESSAGE="$1"
  JOB_FAILURE_EXIT_CODE="${2:-1}"
  JOB_FAILURE_STAGE="${3:-preflight}"

  if job_status_update finish \
    --exit-code "$JOB_FAILURE_EXIT_CODE" \
    --error-message "$JOB_FAILURE_MESSAGE" \
    --failure-stage "$JOB_FAILURE_STAGE"; then
    :
  else
    JOB_STATUS_FAILURE_CODE=$?
    warn "Failed to persist FAILED status; helper exit code ${JOB_STATUS_FAILURE_CODE}"
  fi
}

die() {
  DIE_MESSAGE="$*"
  printf '[openclaw-agent][ERROR] %s\n' "$DIE_MESSAGE" >&2
  mark_job_failed_best_effort "$DIE_MESSAGE" 1 "preflight"
  exit 1
}

# Allow manual command override, for example:
# docker run --rm IMAGE openclaw --version
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

export OPENCLAW_HOME="${OPENCLAW_HOME:-/home/node/.openclaw}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/home/node/.openclaw/openclaw.json}"
export OPENCLAW_TEMPLATE_PATH="${OPENCLAW_TEMPLATE_PATH:-/app/config/openclaw.template.json}"
export OPENCLAW_RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-/app/runtime}"
export OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-${OPENCLAW_RUNTIME_DIR}/workspace}"
export OPENCLAW_EFS_HISTORY_ENABLED="${OPENCLAW_EFS_HISTORY_ENABLED:-true}"
export OPENCLAW_EFS_HISTORY_STRICT="${OPENCLAW_EFS_HISTORY_STRICT:-false}"
export OPENCLAW_EFS_HISTORY_DIR="${OPENCLAW_EFS_HISTORY_DIR:-${OPENCLAW_RUNTIME_DIR}/history}"
export OPENCLAW_EFS_HISTORY_TASK_TYPES="${OPENCLAW_EFS_HISTORY_TASK_TYPES:-alert_analysis,daily_inspection,cost_inspection}"
export OPENCLAW_EFS_HISTORY_RETENTION_DAYS="${OPENCLAW_EFS_HISTORY_RETENTION_DAYS:-30}"
export OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES="${OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES:-262144}"
export OPENCLAW_RESULT_CAPTURE_MAX_BYTES="${OPENCLAW_RESULT_CAPTURE_MAX_BYTES:-1048576}"
export OPENCLAW_REPORT_EFS_AGGREGATE="${OPENCLAW_REPORT_EFS_AGGREGATE:-true}"
export OPENCLAW_REPORT_EFS_LOOKBACK_HOURS="${OPENCLAW_REPORT_EFS_LOOKBACK_HOURS:-168}"
export OPENCLAW_REPORT_EFS_MAX_ITEMS="${OPENCLAW_REPORT_EFS_MAX_ITEMS:-100}"
export OPENCLAW_AUTO_REPORT_ENABLED="${OPENCLAW_AUTO_REPORT_ENABLED:-true}"
export OPENCLAW_AUTO_REPORT_UPLOAD_S3="${OPENCLAW_AUTO_REPORT_UPLOAD_S3:-true}"
export OPENCLAW_AUTO_REPORT_WRITE_INDEX="${OPENCLAW_AUTO_REPORT_WRITE_INDEX:-false}"
export OPENCLAW_AUTO_REPORT_SUMMARY_MODE="${OPENCLAW_AUTO_REPORT_SUMMARY_MODE:-auto}"
export OPENCLAW_AUTO_REPORT_STRICT="${OPENCLAW_AUTO_REPORT_STRICT:-false}"
export OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS="${OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS:-120}"

export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"

export OPENCLAW_TASK_TYPE="${OPENCLAW_TASK_TYPE:-healthcheck}"
export OPENCLAW_JOB_ID="${OPENCLAW_JOB_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}"
export OPENCLAW_TARGET="${OPENCLAW_TARGET:-aws-account}"
export OPENCLAW_PRIORITY="${OPENCLAW_PRIORITY:-normal}"
export OPENCLAW_JOB_STATUS_ENABLED="${OPENCLAW_JOB_STATUS_ENABLED:-true}"
export OPENCLAW_JOB_STATUS_STRICT="${OPENCLAW_JOB_STATUS_STRICT:-false}"
export OPENCLAW_JOB_STATUS_HELPER="${OPENCLAW_JOB_STATUS_HELPER:-/app/skills/_shared/job_status_store.py}"

export QQBOT_ENABLED="${QQBOT_ENABLED:-false}"
export QQBOT_APP_ID="${QQBOT_APP_ID:-}"
export QQBOT_CLIENT_SECRET="${QQBOT_CLIENT_SECRET:-}"
export QQBOT_NAME="${QQBOT_NAME:-OpenClaw QQBot}"

if [ ! -f "$OPENCLAW_TEMPLATE_PATH" ]; then
  die "Config template not found: $OPENCLAW_TEMPLATE_PATH"
fi

mkdir -p "$OPENCLAW_HOME"
mkdir -p "$(dirname "$OPENCLAW_CONFIG_PATH")"
mkdir -p "$OPENCLAW_RUNTIME_DIR"
mkdir -p "$OPENCLAW_WORKSPACE"
mkdir -p "$OPENCLAW_RUNTIME_DIR/logs"
mkdir -p "$OPENCLAW_RUNTIME_DIR/reports"
mkdir -p "$OPENCLAW_EFS_HISTORY_DIR"

# Generate a local gateway token if it is not provided.
# This token is not the DeepSeek API key.
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  OPENCLAW_GATEWAY_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
  export OPENCLAW_GATEWAY_TOKEN
fi

# QQBot is reserved for future integration.
# If explicitly enabled, credentials must be provided at runtime.
case "$(printf '%s' "$QQBOT_ENABLED" | tr '[:upper:]' '[:lower:]')" in
  true|1|yes|on|enabled)
    export QQBOT_ENABLED="true"
    if [ -z "$QQBOT_APP_ID" ]; then
      die "QQBOT_ENABLED=true but QQBOT_APP_ID is empty"
    fi
    if [ -z "$QQBOT_CLIENT_SECRET" ]; then
      die "QQBOT_ENABLED=true but QQBOT_CLIENT_SECRET is empty"
    fi
    ;;
  *)
    export QQBOT_ENABLED="false"
    ;;
esac

# DeepSeek API key is expected as an environment variable named DEEPSEEK_API_KEY.
# The template placeholder __DEEPSEEK_API_KEY__ is replaced with the env var name,
# not with the secret value itself.
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  warn "DEEPSEEK_API_KEY is empty. LLM-related OpenClaw tasks may fail."
fi

python3 - <<'PY'
import json
import os
from pathlib import Path

template_path = Path(os.environ["OPENCLAW_TEMPLATE_PATH"])
config_path = Path(os.environ["OPENCLAW_CONFIG_PATH"])

text = template_path.read_text(encoding="utf-8")

qqbot_enabled = os.environ.get("QQBOT_ENABLED", "false").lower() == "true"

replacements = {
    '"__OPENCLAW_WORKSPACE__"': json.dumps(os.environ["OPENCLAW_WORKSPACE"]),
    '"__OPENCLAW_GATEWAY_TOKEN__"': json.dumps(os.environ["OPENCLAW_GATEWAY_TOKEN"]),

    # This is intentionally the environment variable NAME, not the secret value.
    '"__DEEPSEEK_API_KEY__"': json.dumps("DEEPSEEK_API_KEY"),

    '"__QQBOT_ENABLED__"': "true" if qqbot_enabled else "false",
    '"__QQBOT_APP_ID__"': json.dumps(os.environ.get("QQBOT_APP_ID", "")),
    '"__QQBOT_CLIENT_SECRET__"': json.dumps(os.environ.get("QQBOT_CLIENT_SECRET", "")),
    '"__QQBOT_NAME__"': json.dumps(os.environ.get("QQBOT_NAME", "OpenClaw QQBot")),
}

for old, new in replacements.items():
    text = text.replace(old, new)

# Validate rendered JSON before writing.
try:
    json.loads(text)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Rendered openclaw.json is invalid JSON: {exc}")

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(text, encoding="utf-8")
PY

chmod 600 "$OPENCLAW_CONFIG_PATH" || true

log "Generated OpenClaw config: $OPENCLAW_CONFIG_PATH"
log "OpenClaw home: $OPENCLAW_HOME"
log "Runtime dir: $OPENCLAW_RUNTIME_DIR"
log "Workspace: $OPENCLAW_WORKSPACE"
log "EFS history dir: $OPENCLAW_EFS_HISTORY_DIR"
log "AWS region: $AWS_REGION"
log "Task type: $OPENCLAW_TASK_TYPE"
log "Job id: $OPENCLAW_JOB_ID"
log "Target: $OPENCLAW_TARGET"
log "Priority: $OPENCLAW_PRIORITY"

if [ -f /app/VERSION ]; then
  log "Agent version: $(cat /app/VERSION)"
fi

if command -v openclaw >/dev/null 2>&1; then
  log "OpenClaw CLI detected: $(openclaw --version 2>/dev/null || echo unknown)"
else
  die "openclaw command not found in PATH"
fi

PROMPT_FILE=""

case "$OPENCLAW_TASK_TYPE" in
  healthcheck|task-healthcheck|aws-task-healthcheck)
    SKILL_NAME="aws-task-healthcheck"
    PROMPT_FILE="/app/prompts/healthcheck_prompt.txt"
    ;;

  daily_inspection|daily-inspection|aws-daily-inspection)
    SKILL_NAME="aws-daily-inspection"
    PROMPT_FILE="/app/prompts/daily_inspection_prompt.txt"
    ;;

  cost_inspection|cost-inspection|aws-cost-inspection)
    SKILL_NAME="aws-cost-inspection"
    PROMPT_FILE="/app/prompts/cost_inspection_prompt.txt"
    ;;

  alert_analysis|alert-analysis|aws-alert-analysis)
    SKILL_NAME="aws-alert-analysis"
    PROMPT_FILE="/app/prompts/alert_analysis_prompt.txt"
    ;;

  report_generation|report-generation|aws-report-generation)
    SKILL_NAME="aws-report-generation"
    PROMPT_FILE="/app/prompts/report_generation_prompt.txt"
    ;;

  *)
    die "Unsupported OPENCLAW_TASK_TYPE: $OPENCLAW_TASK_TYPE"
    ;;
esac

export OPENCLAW_SELECTED_SKILL="$SKILL_NAME"

if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
  export OPENCLAW_PROMPT_PATH="$PROMPT_FILE"
  log "Prompt file: $OPENCLAW_PROMPT_PATH"
else
  warn "Prompt file not found for task type: $OPENCLAW_TASK_TYPE"
fi

SKILL_RUNNER="/app/skills/${SKILL_NAME}/run_with_ecs_credentials.sh"

if [ ! -f "$SKILL_RUNNER" ]; then
  die "Skill runner not found: $SKILL_RUNNER"
fi

if [ ! -x "$SKILL_RUNNER" ]; then
  die "Skill runner is not executable: $SKILL_RUNNER"
fi

log "Starting skill: $SKILL_NAME"

if job_status_update start; then
  log "Jobs lifecycle status updated to RUNNING or safely skipped"
else
  JOB_STATUS_START_EXIT_CODE=$?
  warn "Failed to update Jobs status to RUNNING; helper exit code ${JOB_STATUS_START_EXIT_CODE}"

  if job_status_flag_enabled "$OPENCLAW_JOB_STATUS_STRICT"; then
    mark_job_failed_best_effort \
      "Failed to persist RUNNING status" \
      "$JOB_STATUS_START_EXIT_CODE" \
      "job_status_start"

    exit "$JOB_STATUS_START_EXIT_CODE"
  fi
fi

# The per-task result is transient. Only the allowlisted sanitized history
# record is persisted to EFS by the shared history store.
export OPENCLAW_RESULT_FILE="${OPENCLAW_RESULT_FILE:-/tmp/openclaw-results/${OPENCLAW_JOB_ID}.json}"
mkdir -p "$(dirname "$OPENCLAW_RESULT_FILE")"

HISTORY_STORE="/app/skills/_shared/efs_history_store.py"
CAPTURE_SKILL_OUTPUT=false

case "$SKILL_NAME" in
  aws-task-healthcheck|aws-daily-inspection|aws-cost-inspection)
    CAPTURE_SKILL_OUTPUT=true
    ;;
esac

if [ "$CAPTURE_SKILL_OUTPUT" = "true" ]; then
  SKILL_OUTPUT_FILE="$(mktemp /tmp/openclaw-skill-output.XXXXXX)"

  cleanup_skill_output() {
    rm -f "$SKILL_OUTPUT_FILE"
  }
  trap cleanup_skill_output EXIT HUP INT TERM

  if "$SKILL_RUNNER" >"$SKILL_OUTPUT_FILE" 2>&1; then
    SKILL_EXIT_CODE=0
  else
    SKILL_EXIT_CODE=$?
  fi

  cat "$SKILL_OUTPUT_FILE"

  if [ ! -s "$OPENCLAW_RESULT_FILE" ] && [ -f "$HISTORY_STORE" ]; then
    log "Capturing structured result from skill output"
    if ! python3 "$HISTORY_STORE" capture \
      --source-file "$SKILL_OUTPUT_FILE" \
      --output-file "$OPENCLAW_RESULT_FILE"; then
      warn "Structured result capture failed"
    fi
  fi

  cleanup_skill_output
  trap - EXIT HUP INT TERM
else
  if "$SKILL_RUNNER"; then
    SKILL_EXIT_CODE=0
  else
    SKILL_EXIT_CODE=$?
  fi
fi

HISTORY_EXIT_CODE=0

case "$(printf '%s' "$OPENCLAW_EFS_HISTORY_ENABLED" | tr '[:upper:]' '[:lower:]')" in
  true|1|yes|on|enabled)
    if [ -f "$HISTORY_STORE" ]; then
      log "Archiving sanitized task result to EFS history"
      if python3 "$HISTORY_STORE" archive \
        --result-file "$OPENCLAW_RESULT_FILE" \
        --exit-code "$SKILL_EXIT_CODE"; then
        HISTORY_EXIT_CODE=0
      else
        HISTORY_EXIT_CODE=$?
        warn "EFS history archival failed with exit code ${HISTORY_EXIT_CODE}"
      fi
    else
      HISTORY_EXIT_CODE=1
      warn "EFS history store not found: $HISTORY_STORE"
    fi
    ;;
  *)
    log "EFS task history is disabled"
    ;;
esac

# Generate a human-readable report for the four operational source skills.
# The source result remains authoritative and is never overwritten by reporting.
AUTO_REPORT_EXIT_CODE=0
AUTO_REPORT_ELIGIBLE=false

case "$SKILL_NAME" in
  aws-task-healthcheck|aws-daily-inspection|aws-cost-inspection|aws-alert-analysis)
    AUTO_REPORT_ELIGIBLE=true
    ;;
esac

if job_status_flag_enabled "$OPENCLAW_AUTO_REPORT_ENABLED" && [ "$AUTO_REPORT_ELIGIBLE" = "true" ]; then
  REPORT_RUNNER="/app/skills/aws-report-generation/run_with_ecs_credentials.sh"
  REPORT_RESULT_FILE="/tmp/openclaw-report-results/${OPENCLAW_JOB_ID}.json"

  if [ ! -s "$OPENCLAW_RESULT_FILE" ]; then
    AUTO_REPORT_EXIT_CODE=2
    warn "Automatic report skipped because the source result file is missing or empty: $OPENCLAW_RESULT_FILE"
  elif [ ! -x "$REPORT_RUNNER" ]; then
    AUTO_REPORT_EXIT_CODE=2
    warn "Automatic report runner not found or not executable: $REPORT_RUNNER"
  else
    mkdir -p "$(dirname "$REPORT_RESULT_FILE")"
    SOURCE_TASK_TYPE_FOR_REPORT="$OPENCLAW_TASK_TYPE"
    SOURCE_SKILL_FOR_REPORT="$SKILL_NAME"
    log "Generating post-task human-readable report"

    if OPENCLAW_TASK_TYPE="report_generation" \
      OPENCLAW_SELECTED_SKILL="aws-report-generation" \
      OPENCLAW_SOURCE_TASK_TYPE="$SOURCE_TASK_TYPE_FOR_REPORT" \
      OPENCLAW_SOURCE_SKILL="$SOURCE_SKILL_FOR_REPORT" \
      OPENCLAW_REPORT_INPUT_JSON="" \
      OPENCLAW_REPORT_INPUT_FILE="$OPENCLAW_RESULT_FILE" \
      OPENCLAW_REPORT_REQUIRE_INPUT="true" \
      OPENCLAW_REPORT_UPLOAD_S3="$OPENCLAW_AUTO_REPORT_UPLOAD_S3" \
      OPENCLAW_REPORT_WRITE_INDEX="$OPENCLAW_AUTO_REPORT_WRITE_INDEX" \
      OPENCLAW_REPORT_SUMMARY_MODE="$OPENCLAW_AUTO_REPORT_SUMMARY_MODE" \
      OPENCLAW_REPORT_PROMPT_PATH="/app/prompts/report_generation_prompt.txt" \
      OPENCLAW_RESULT_FILE="$REPORT_RESULT_FILE" \
      "$REPORT_RUNNER"; then
      AUTO_REPORT_EXIT_CODE=0
      log "Automatic report generation completed"
    else
      AUTO_REPORT_EXIT_CODE=$?
      warn "Automatic report generation failed with exit code ${AUTO_REPORT_EXIT_CODE}"
    fi
  fi
else
  if [ "$AUTO_REPORT_ELIGIBLE" = "true" ]; then
    log "Automatic post-task report generation is disabled"
  fi
fi

NOTIFICATION_DISPATCHER="/app/skills/_shared/notification_dispatcher.py"
NOTIFICATION_EXIT_CODE=0

case "$(printf '%s' "${OPENCLAW_SNS_NOTIFY_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
  true|1|yes|on|enabled)
    if [ -f "$NOTIFICATION_DISPATCHER" ]; then
      log "Dispatching post-task SNS notification"
      if python3 "$NOTIFICATION_DISPATCHER" \
        --result-file "$OPENCLAW_RESULT_FILE" \
        --exit-code "$SKILL_EXIT_CODE"; then
        NOTIFICATION_EXIT_CODE=0
      else
        NOTIFICATION_EXIT_CODE=$?
        warn "SNS notification dispatcher failed with exit code ${NOTIFICATION_EXIT_CODE}"
      fi
    else
      NOTIFICATION_EXIT_CODE=1
      warn "SNS notification dispatcher not found: $NOTIFICATION_DISPATCHER"
    fi
    ;;
  *)
    log "SNS business notifications are disabled"
    ;;
esac

FINAL_EXIT_CODE=0
FINAL_FAILURE_STAGE=""
FINAL_ERROR_MESSAGE=""

if [ "$SKILL_EXIT_CODE" -ne 0 ]; then
  FINAL_EXIT_CODE="$SKILL_EXIT_CODE"
  FINAL_FAILURE_STAGE="skill"
  FINAL_ERROR_MESSAGE="Skill execution failed with exit code ${SKILL_EXIT_CODE}"
elif job_status_flag_enabled "$OPENCLAW_EFS_HISTORY_STRICT" \
  && [ "$HISTORY_EXIT_CODE" -ne 0 ]; then
  FINAL_EXIT_CODE="$HISTORY_EXIT_CODE"
  FINAL_FAILURE_STAGE="efs_history"
  FINAL_ERROR_MESSAGE="EFS history archival failed with exit code ${HISTORY_EXIT_CODE}"
elif job_status_flag_enabled "$OPENCLAW_AUTO_REPORT_STRICT" \
  && [ "$AUTO_REPORT_EXIT_CODE" -ne 0 ]; then
  FINAL_EXIT_CODE="$AUTO_REPORT_EXIT_CODE"
  FINAL_FAILURE_STAGE="report_generation"
  FINAL_ERROR_MESSAGE="Automatic report generation failed with exit code ${AUTO_REPORT_EXIT_CODE}"
elif job_status_flag_enabled "${OPENCLAW_SNS_NOTIFY_STRICT:-false}" \
  && [ "$NOTIFICATION_EXIT_CODE" -ne 0 ]; then
  FINAL_EXIT_CODE="$NOTIFICATION_EXIT_CODE"
  FINAL_FAILURE_STAGE="sns_notification"
  FINAL_ERROR_MESSAGE="SNS notification failed with exit code ${NOTIFICATION_EXIT_CODE}"
fi

if [ -n "$FINAL_ERROR_MESSAGE" ]; then
  if job_status_update finish \
    --exit-code "$FINAL_EXIT_CODE" \
    --result-file "$OPENCLAW_RESULT_FILE" \
    --error-message "$FINAL_ERROR_MESSAGE" \
    --failure-stage "$FINAL_FAILURE_STAGE"; then
    log "Jobs lifecycle terminal status persisted"
  else
    JOB_STATUS_FINAL_EXIT_CODE=$?
    warn "Failed to persist terminal Jobs status; helper exit code ${JOB_STATUS_FINAL_EXIT_CODE}"

    if job_status_flag_enabled "$OPENCLAW_JOB_STATUS_STRICT" \
      && [ "$FINAL_EXIT_CODE" -eq 0 ]; then
      FINAL_EXIT_CODE="$JOB_STATUS_FINAL_EXIT_CODE"
    fi
  fi
else
  if job_status_update finish \
    --exit-code "$FINAL_EXIT_CODE" \
    --result-file "$OPENCLAW_RESULT_FILE"; then
    log "Jobs lifecycle terminal status persisted"
  else
    JOB_STATUS_FINAL_EXIT_CODE=$?
    warn "Failed to persist terminal Jobs status; helper exit code ${JOB_STATUS_FINAL_EXIT_CODE}"

    if job_status_flag_enabled "$OPENCLAW_JOB_STATUS_STRICT"; then
      FINAL_EXIT_CODE="$JOB_STATUS_FINAL_EXIT_CODE"
    fi
  fi
fi

exit "$FINAL_EXIT_CODE"
