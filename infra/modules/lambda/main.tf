data "archive_file" "job_receiver" {
  type                    = "zip"
  source_content_filename = "job_receiver.py"
  output_path             = "${path.module}/job_receiver.zip"

  source_content = <<-PY
"""Unified OpenClaw-AWS job ingress.

Accepted event sources:
- API Gateway HTTP API (Amazon Quick/OpenAPI or direct API callers)
- EventBridge Scheduler (scheduled-job envelope)
- EventBridge CloudWatch Alarm State Change events

Every accepted event creates the same DynamoDB Jobs lifecycle record before the
Step Functions workflow is started.  The ECS agent remains responsible for the
RUNNING and terminal lifecycle updates.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

DYNAMODB = boto3.resource("dynamodb")
STEP_FUNCTIONS = boto3.client("stepfunctions")

JOBS_TABLE_NAME = os.environ["JOBS_TABLE_NAME"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
JOB_RETENTION_DAYS = int(os.environ.get("JOB_RETENTION_DAYS", "90"))
ENVIRONMENT = os.environ.get("OPENCLAW_ENVIRONMENT", "unknown")

JOBS_TABLE = DYNAMODB.Table(JOBS_TABLE_NAME)

SUPPORTED_TASK_TYPES = {
    "healthcheck",
    "daily_inspection",
    "cost_inspection",
    "alert_analysis",
    "report_generation",
}
SUPPORTED_PRIORITIES = {"high", "medium", "low"}
SUPPORTED_TARGETS = {"aws-account"}
# ECS RunTask container overrides have a small request-size ceiling. Keep the
# structured alert below 6 KiB so all override fields remain safely bounded.
MAX_ALERT_JSON_BYTES = 6000
API_REQUIRED_FIELDS = {"task_type", "priority", "target"}
API_ALLOWED_FIELDS = API_REQUIRED_FIELDS | {"alert_payload"}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _format_utc(value: datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _response(status_code: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "content-type": "application/json",
            "cache-control": "no-store",
        },
        "body": json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
        "isBase64Encoded": False,
    }


def _compact_json(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _parse_api_body(event: dict[str, Any]) -> dict[str, Any]:
    raw_body = event.get("body")
    if raw_body is None:
        raise ValueError("Request body is required.")

    if event.get("isBase64Encoded"):
        try:
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError("Request body is not valid base64-encoded UTF-8.") from exc

    if isinstance(raw_body, dict):
        body = raw_body
    elif isinstance(raw_body, str):
        try:
            body = json.loads(raw_body)
        except json.JSONDecodeError as exc:
            raise ValueError("Request body must be valid JSON.") from exc
    else:
        raise ValueError("Request body must be a JSON object.")

    if not isinstance(body, dict):
        raise ValueError("Request body must be a JSON object.")
    return body


def _required_string(body: dict[str, Any], field: str) -> str:
    value = body.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string.")
    return value.strip()


def _validate_common(task_type: str, priority: str, target: str) -> None:
    if task_type not in SUPPORTED_TASK_TYPES:
        raise ValueError(
            "task_type must be one of: " + ", ".join(sorted(SUPPORTED_TASK_TYPES))
        )
    if priority not in SUPPORTED_PRIORITIES:
        raise ValueError("priority must be high, medium, or low.")
    if target not in SUPPORTED_TARGETS:
        raise ValueError("The current deployment supports only target=aws-account.")


def _normalize_api_event(event: dict[str, Any], context: Any) -> dict[str, Any]:
    body = _parse_api_body(event)
    unexpected = sorted(set(body) - API_ALLOWED_FIELDS)
    if unexpected:
        raise ValueError("Unsupported request fields: " + ", ".join(unexpected))
    missing = sorted(API_REQUIRED_FIELDS - set(body))
    if missing:
        raise ValueError("Missing required fields: " + ", ".join(missing))

    task_type = _required_string(body, "task_type")
    priority = _required_string(body, "priority")
    target = _required_string(body, "target")
    _validate_common(task_type, priority, target)

    alert_payload = body.get("alert_payload")
    if task_type == "alert_analysis":
        if not isinstance(alert_payload, dict) or not alert_payload:
            raise ValueError(
                "alert_payload must be a non-empty JSON object for alert_analysis."
            )
    elif alert_payload is not None:
        raise ValueError("alert_payload is supported only for alert_analysis.")

    request_context = event.get("requestContext") or {}
    request_id = request_context.get("requestId") or getattr(
        context, "aws_request_id", "unknown"
    )
    return {
        "task_type": task_type,
        "priority": priority,
        "target": target,
        "source": "quick",
        "source_request_id": str(request_id),
        "alert_payload": alert_payload or {},
        "metadata": {"api_request_id": str(request_id)},
    }


def _normalize_scheduler_event(event: dict[str, Any]) -> dict[str, Any]:
    task_type = _required_string(event, "task_type")
    priority = _required_string(event, "priority")
    target = _required_string(event, "target")
    _validate_common(task_type, priority, target)

    execution_id = _required_string(event, "execution_id")
    schedule_name = _required_string(event, "schedule_name")
    scheduled_time = _required_string(event, "scheduled_time")
    return {
        "task_type": task_type,
        "priority": priority,
        "target": target,
        "source": "scheduler",
        "source_request_id": execution_id,
        "requested_at": scheduled_time,
        "deduplication_key": f"scheduler:{schedule_name}:{execution_id}",
        "alert_payload": {},
        "metadata": {
            "schedule_name": schedule_name,
            "scheduler_execution_id": execution_id,
        },
    }


def _normalize_alarm_event(event: dict[str, Any]) -> dict[str, Any]:
    detail = event.get("detail")
    if not isinstance(detail, dict):
        raise ValueError("CloudWatch alarm event detail must be a JSON object.")

    state = detail.get("state")
    state_value = state.get("value") if isinstance(state, dict) else None
    if state_value != "ALARM":
        raise ValueError("Only CloudWatch ALARM state events are accepted.")

    alarm_name = detail.get("alarmName")
    if not isinstance(alarm_name, str) or not alarm_name:
        raise ValueError("CloudWatch alarm event is missing detail.alarmName.")

    event_id = event.get("id")
    if not isinstance(event_id, str) or not event_id:
        event_id = hashlib.sha256(_compact_json(event).encode("utf-8")).hexdigest()

    event_time = event.get("time")
    resources = event.get("resources") if isinstance(event.get("resources"), list) else []
    previous_state = detail.get("previousState") if isinstance(detail.get("previousState"), dict) else {}
    compact_event = {
        "version": event.get("version"),
        "id": event_id,
        "detail-type": "CloudWatch Alarm State Change",
        "source": "aws.cloudwatch",
        "account": event.get("account"),
        "time": event_time,
        "region": event.get("region"),
        "resources": resources,
        "AlarmArn": resources[0] if resources else None,
        "detail": {
            "alarmName": alarm_name,
            "state": {
                key: state.get(key)
                for key in ("value", "reason", "timestamp")
                if state.get(key) is not None
            },
            "previousState": {
                key: previous_state.get(key)
                for key in ("value", "reason", "timestamp")
                if previous_state.get(key) is not None
            },
        },
    }
    return {
        "task_type": "alert_analysis",
        "priority": "high",
        "target": "aws-account",
        "source": "cloudwatch-alarm",
        "source_request_id": event_id,
        "requested_at": event_time if isinstance(event_time, str) else None,
        "deduplication_key": f"cloudwatch-alarm:{event_id}",
        "alert_payload": compact_event,
        "metadata": {
            "event_id": event_id,
            "alarm_name": alarm_name,
            "alarm_state": "ALARM",
        },
    }


def _event_kind(event: dict[str, Any]) -> str:
    if event.get("source") == "aws.cloudwatch" and event.get("detail-type") == "CloudWatch Alarm State Change":
        return "alarm"
    if event.get("event_type") == "scheduled-job":
        return "scheduler"
    if "requestContext" in event or "body" in event:
        return "api"
    raise ValueError("Unsupported event source.")


def _job_id_for(normalized: dict[str, Any]) -> str:
    deduplication_key = normalized.get("deduplication_key")
    if isinstance(deduplication_key, str) and deduplication_key:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, deduplication_key))
    return str(uuid.uuid4())


def _safe_execution_name(job_id: str) -> str:
    safe = re.sub(r"[^0-9A-Za-z-_]", "-", job_id)[:80]
    return safe or str(uuid.uuid4())


def _mark_start_failed(job_id: str, message: str) -> None:
    try:
        JOBS_TABLE.update_item(
            Key={"job_id": job_id},
            UpdateExpression=(
                "SET #status = :status, updated_at = :updated_at, "
                "failure_stage = :failure_stage, error_message = :error_message"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":status": "START_FAILED",
                ":updated_at": _format_utc(_utc_now()),
                ":failure_stage": "STEP_FUNCTIONS_START",
                ":error_message": message[:1000],
            },
        )
    except (BotoCoreError, ClientError):
        LOGGER.exception("Failed to mark job as START_FAILED", extra={"job_id": job_id})


def _dispatch(normalized: dict[str, Any]) -> dict[str, Any]:
    now = _utc_now()
    requested_at = normalized.get("requested_at") or _format_utc(now)
    job_id = _job_id_for(normalized)
    expires_at = int(time.time()) + (JOB_RETENTION_DAYS * 86400)
    alert_json = _compact_json(normalized.get("alert_payload") or {})
    alert_json_size = len(alert_json.encode("utf-8"))
    if alert_json_size > MAX_ALERT_JSON_BYTES:
        raise ValueError(
            f"alert_payload exceeds {MAX_ALERT_JSON_BYTES} UTF-8 bytes "
            f"({alert_json_size} bytes received)."
        )

    workflow_input: dict[str, Any] = {
        "job_id": job_id,
        "task_type": normalized["task_type"],
        "priority": normalized["priority"],
        "target": normalized["target"],
        "source": normalized["source"],
        "requested_at": requested_at,
        "alert_json": alert_json,
    }

    metadata = normalized.get("metadata") or {}
    job_item: dict[str, Any] = {
        **{key: value for key, value in workflow_input.items() if key != "alert_json"},
        "status": "RECEIVED",
        "updated_at": requested_at,
        "expires_at": expires_at,
        "environment": ENVIRONMENT,
    }
    for key, value in metadata.items():
        if value is not None:
            job_item[key] = value

    created = True
    try:
        JOBS_TABLE.put_item(
            Item=job_item,
            ConditionExpression="attribute_not_exists(job_id)",
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise
        created = False
        existing = JOBS_TABLE.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item") or {}
        existing_status = existing.get("status", "UNKNOWN")
        if existing_status not in {"RECEIVED", "START_FAILED"}:
            LOGGER.info(
                "Duplicate job event already dispatched",
                extra={"job_id": job_id, "status": existing_status},
            )
            return {
                "accepted": True,
                "duplicate": True,
                "job_id": job_id,
                "status": existing_status,
                "requested_at": existing.get("requested_at", requested_at),
            }
        LOGGER.warning(
            "Retrying a previously un-dispatched job event",
            extra={"job_id": job_id, "status": existing_status},
        )

    execution_name = _safe_execution_name(job_id)
    try:
        execution = STEP_FUNCTIONS.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=execution_name,
            input=_compact_json(workflow_input),
        )
        execution_arn = execution["executionArn"]
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ExecutionAlreadyExists":
            # The workflow started but a previous lifecycle update may have failed.
            # Standard Step Functions execution ARNs are deterministic from the
            # state-machine ARN and execution name, so recover visibility without
            # launching a second workflow.
            execution_arn = (
                STATE_MACHINE_ARN.replace(":stateMachine:", ":execution:")
                + f":{execution_name}"
            )
        else:
            _mark_start_failed(job_id, str(exc))
            raise
    except BotoCoreError as exc:
        _mark_start_failed(job_id, str(exc))
        raise
    dispatching_at = _format_utc(_utc_now())
    try:
        JOBS_TABLE.update_item(
            Key={"job_id": job_id},
            UpdateExpression=(
                "SET #status = :status, execution_arn = :execution_arn, "
                "updated_at = :updated_at"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":status": "DISPATCHING",
                ":execution_arn": execution_arn,
                ":updated_at": dispatching_at,
            },
        )
    except (BotoCoreError, ClientError):
        LOGGER.exception(
            "Workflow started but the Jobs record could not be marked DISPATCHING",
            extra={"job_id": job_id, "execution_arn": execution_arn},
        )

    return {
        "accepted": True,
        "duplicate": not created,
        "job_id": job_id,
        "status": "DISPATCHING",
        "requested_at": requested_at,
        "execution_arn": execution_arn,
    }


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    kind = "unknown"
    try:
        kind = _event_kind(event)
        if kind == "api":
            normalized = _normalize_api_event(event, context)
        elif kind == "scheduler":
            normalized = _normalize_scheduler_event(event)
        else:
            normalized = _normalize_alarm_event(event)
        result = _dispatch(normalized)
    except ValueError as exc:
        LOGGER.warning("Rejected invalid job event", extra={"event_kind": kind, "error": str(exc)})
        if kind == "api":
            return _response(
                400,
                {
                    "accepted": False,
                    "error": "INVALID_REQUEST",
                    "message": str(exc),
                },
            )
        raise
    except (BotoCoreError, ClientError) as exc:
        LOGGER.exception("Failed to accept OpenClaw-AWS job", extra={"event_kind": kind})
        if kind == "api":
            return _response(
                500,
                {
                    "accepted": False,
                    "error": "JOB_DISPATCH_FAILED",
                    "message": type(exc).__name__,
                },
            )
        raise

    LOGGER.info(
        "Accepted OpenClaw-AWS job",
        extra={
            "event_kind": kind,
            "job_id": result["job_id"],
            "status": result["status"],
            "duplicate": result.get("duplicate", False),
        },
    )
    if kind == "api":
        return _response(202, {key: value for key, value in result.items() if key != "execution_arn"})
    return result
  PY
}

data "archive_file" "authorizer" {
  type                    = "zip"
  source_content_filename = "authorizer.py"
  output_path             = "${path.module}/authorizer.zip"

  source_content = <<-PY
"""HTTP API simple-response authorizer for the Amazon Quick API key."""
from __future__ import annotations

import hmac
import json
import logging
import os
import time
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
SECRETS_MANAGER = boto3.client("secretsmanager")

QUICK_API_KEY_SECRET_ARN = os.environ["QUICK_API_KEY_SECRET_ARN"]
QUICK_API_KEY_JSON_KEY = os.environ.get("QUICK_API_KEY_JSON_KEY", "QUICK_API_KEY")
SECRET_CACHE_SECONDS = int(os.environ.get("SECRET_CACHE_SECONDS", "60"))
_SECRET_CACHE: dict[str, Any] = {"value": None, "expires_at": 0.0}


def _load_expected_api_key() -> str:
    now = time.monotonic()
    value = _SECRET_CACHE.get("value")
    if isinstance(value, str) and value and now < float(_SECRET_CACHE.get("expires_at", 0.0)):
        return value

    response = SECRETS_MANAGER.get_secret_value(SecretId=QUICK_API_KEY_SECRET_ARN)
    secret_string = response.get("SecretString")
    if not isinstance(secret_string, str) or not secret_string:
        raise ValueError("Quick API key secret does not contain SecretString.")
    try:
        document = json.loads(secret_string)
    except json.JSONDecodeError as exc:
        raise ValueError("Quick API key secret must contain a JSON object.") from exc
    if not isinstance(document, dict):
        raise ValueError("Quick API key secret must contain a JSON object.")
    expected = document.get(QUICK_API_KEY_JSON_KEY)
    if not isinstance(expected, str) or not expected:
        raise ValueError(f"Quick API key secret is missing JSON key {QUICK_API_KEY_JSON_KEY}.")
    _SECRET_CACHE.update(value=expected, expires_at=now + SECRET_CACHE_SECONDS)
    return expected


def _get_header(headers: dict[str, Any], name: str) -> str:
    requested = name.lower()
    for key, value in headers.items():
        if str(key).lower() == requested and isinstance(value, str):
            return value.strip()
    return ""


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    request_context = event.get("requestContext") or {}
    request_id = request_context.get("requestId") or getattr(context, "aws_request_id", "unknown")
    route_key = event.get("routeKey") or request_context.get("routeKey", "unknown")
    supplied = _get_header(event.get("headers") or {}, "x-api-key")
    authorized = False
    if supplied:
        try:
            authorized = hmac.compare_digest(supplied.encode(), _load_expected_api_key().encode())
        except (BotoCoreError, ClientError, ValueError):
            LOGGER.exception("Unable to evaluate the Quick API key", extra={"request_id": request_id})
    LOGGER.info(
        "API authorization decision",
        extra={"request_id": request_id, "route_key": route_key, "is_authorized": authorized},
    )
    return {
        "isAuthorized": authorized,
        "context": {
            "principal": "amazon-quick" if authorized else "unauthorized",
            "requestId": request_id,
        },
    }
  PY
}

resource "aws_lambda_function" "job_receiver" {
  function_name = "${var.name_prefix}-job-receiver"
  description   = "Creates Jobs lifecycle records for API, Scheduler, and CloudWatch Alarm events, then starts the OpenClaw workflow."
  role          = var.job_receiver_role_arn
  handler       = "job_receiver.lambda_handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.job_receiver.output_path
  source_code_hash = data.archive_file.job_receiver.output_base64sha256

  memory_size = var.job_receiver_memory_size
  timeout     = var.job_receiver_timeout_seconds

  environment {
    variables = {
      JOBS_TABLE_NAME      = var.jobs_table_name
      STATE_MACHINE_ARN    = var.state_machine_arn
      JOB_RETENTION_DAYS   = tostring(var.job_retention_days)
      OPENCLAW_ENVIRONMENT = var.environment
      LOG_LEVEL            = var.application_log_level
    }
  }

  logging_config {
    log_format            = "JSON"
    log_group             = var.job_receiver_log_group_name
    application_log_level = var.application_log_level
    system_log_level      = var.system_log_level
  }

  tags = {
    Name = "${var.name_prefix}-job-receiver"
  }
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${var.name_prefix}-api-authorizer"
  description   = "Validates the x-api-key header against the dedicated Amazon Quick API key secret."
  role          = var.authorizer_role_arn
  handler       = "authorizer.lambda_handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  memory_size = var.authorizer_memory_size
  timeout     = var.authorizer_timeout_seconds

  environment {
    variables = {
      QUICK_API_KEY_SECRET_ARN = var.quick_api_key_secret_arn
      QUICK_API_KEY_JSON_KEY   = "QUICK_API_KEY"
      SECRET_CACHE_SECONDS     = tostring(var.authorizer_secret_cache_seconds)
      LOG_LEVEL                = var.application_log_level
    }
  }

  logging_config {
    log_format            = "JSON"
    log_group             = var.authorizer_log_group_name
    application_log_level = var.application_log_level
    system_log_level      = var.system_log_level
  }

  tags = {
    Name = "${var.name_prefix}-api-authorizer"
  }
}


resource "aws_cloudwatch_metric_alarm" "job_receiver_errors" {
  count = var.operational_alarms_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-job-receiver-errors"
  alarm_description   = "OpenClaw job receiver Lambda reported one or more errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.job_receiver.function_name
  }

  tags = {
    Name = "${var.name_prefix}-job-receiver-errors"
  }
}
