#!/usr/bin/env python3
"""OpenClaw-AWS alert analysis skill.

The module deliberately separates input normalization, read-only AWS context
collection, analysis, and optional persistence so each layer can be tested
without real AWS credentials.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional

try:
    import boto3
    from boto3.dynamodb.types import TypeSerializer
    from botocore.exceptions import ClientError
except Exception as exc:  # pragma: no cover - exercised only in broken images
    print(
        json.dumps(
            {
                "schema_version": "1.0",
                "task_type": "alert_analysis",
                "status": "failed",
                "overall_ok": False,
                "fatal_error": "boto3_import_failed",
                "detail": str(exc),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    raise SystemExit(1)


SCHEMA_VERSION = "1.0"
DEFAULT_REGION = "ap-northeast-1"

SENSITIVE_KEYWORDS = (
    "secret",
    "token",
    "password",
    "passwd",
    "api_key",
    "apikey",
    "authorization",
    "client_secret",
    "access_key",
    "secret_key",
    "session_token",
    "credential",
)

SENSITIVE_VALUE_PATTERNS = (
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    re.compile(
        r"(?i)\b(authorization|api[_-]?key|access[_-]?key|secret|token|password)"
        r"\s*[:=]\s*([^\s,;]+)"
    ),
)


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def get_region() -> str:
    return os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or DEFAULT_REGION


def env_value(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "enabled"}


def jsonable(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Mapping):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [jsonable(item) for item in value]
    return value


def sanitize_text(value: str) -> str:
    result = value
    result = SENSITIVE_VALUE_PATTERNS[0].sub("Bearer ***REDACTED***", result)
    result = SENSITIVE_VALUE_PATTERNS[1].sub("***REDACTED_AWS_ACCESS_KEY***", result)
    result = SENSITIVE_VALUE_PATTERNS[2].sub(lambda match: f"{match.group(1)}=***REDACTED***", result)
    return result


def sanitize(value: Any) -> Any:
    if isinstance(value, Mapping):
        sanitized: Dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            if any(keyword in key_text.lower() for keyword in SENSITIVE_KEYWORDS):
                sanitized[key_text] = "***REDACTED***"
            else:
                sanitized[key_text] = sanitize(item)
        return sanitized
    if isinstance(value, (list, tuple, set)):
        return [sanitize(item) for item in value]
    if isinstance(value, str):
        return sanitize_text(value)
    return value


def canonical_json(value: Any) -> str:
    return json.dumps(jsonable(value), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def error_result(exc: Exception) -> Dict[str, Any]:
    result: Dict[str, Any] = {
        "ok": False,
        "error_type": exc.__class__.__name__,
        "error": sanitize_text(str(exc)),
    }
    if isinstance(exc, ClientError):
        error = exc.response.get("Error", {})
        result["aws_error_code"] = error.get("Code")
        result["aws_error_message"] = sanitize_text(str(error.get("Message") or ""))
    return result


def read_json_file(path: str) -> Any:
    target = Path(path)
    if not target.exists():
        raise FileNotFoundError(f"Alert file not found: {path}")
    if not target.is_file():
        raise ValueError(f"Alert file is not a regular file: {path}")
    return json.loads(target.read_text(encoding="utf-8"))


def load_alert_input() -> Dict[str, Any]:
    sources = (
        ("OPENCLAW_ALERT_JSON", env_value("OPENCLAW_ALERT_JSON"), False),
        ("OPENCLAW_ALERT_FILE", env_value("OPENCLAW_ALERT_FILE"), True),
        ("OPENCLAW_EVENT_JSON", env_value("OPENCLAW_EVENT_JSON"), False),
    )

    for source_name, raw_value, is_file in sources:
        if not raw_value:
            continue
        try:
            payload = read_json_file(raw_value) if is_file else json.loads(raw_value)
            if not isinstance(payload, Mapping):
                raise ValueError("Alert payload must be a JSON object.")
            return {"ok": True, "source": source_name, "payload": sanitize(dict(payload))}
        except Exception as exc:
            result = error_result(exc)
            result.update({"source": source_name})
            return result

    fallback_payload = {
        "alert_source": env_value("OPENCLAW_ALERT_SOURCE"),
        "alert_name": env_value("OPENCLAW_ALERT_NAME") or env_value("OPENCLAW_ALARM_NAME"),
        "alarm_name": env_value("OPENCLAW_ALARM_NAME"),
        "alarm_arn": env_value("OPENCLAW_ALARM_ARN"),
        "severity": env_value("OPENCLAW_ALERT_SEVERITY"),
        "state": env_value("OPENCLAW_ALERT_STATE"),
        "message": env_value("OPENCLAW_ALERT_MESSAGE"),
        "log_group_name": env_value("OPENCLAW_LOG_GROUP_NAME"),
        "log_stream_name": env_value("OPENCLAW_LOG_STREAM_NAME"),
    }
    fallback_payload = {key: value for key, value in fallback_payload.items() if value}
    return {
        "ok": True,
        "source": "environment_fields" if fallback_payload else "empty",
        "payload": sanitize(fallback_payload),
    }


def unwrap_sns_message(payload: Mapping[str, Any]) -> Dict[str, Any]:
    message = payload.get("Message")
    if not isinstance(message, str):
        return dict(payload)
    try:
        decoded = json.loads(message)
    except json.JSONDecodeError:
        return dict(payload)
    if not isinstance(decoded, Mapping):
        return dict(payload)
    result = dict(decoded)
    result["_sns"] = {
        "message_id": payload.get("MessageId"),
        "topic_arn": payload.get("TopicArn"),
        "timestamp": payload.get("Timestamp"),
        "subject": payload.get("Subject"),
    }
    return result


def first_nonempty(values: Iterable[Any]) -> Any:
    for value in values:
        if value is not None and value != "":
            return value
    return None


def normalize_alert(payload: Mapping[str, Any]) -> Dict[str, Any]:
    raw = unwrap_sns_message(payload)
    detail = raw.get("detail") if isinstance(raw.get("detail"), Mapping) else {}
    state_detail = detail.get("state") if isinstance(detail.get("state"), Mapping) else {}

    event_source = str(raw.get("source") or "")
    detail_type = str(raw.get("detail-type") or raw.get("detail_type") or "")

    if detail_type == "ECS Task State Change" or event_source == "aws.ecs":
        event_type = "ecs_task_state_change"
        name = first_nonempty(
            [
                detail.get("taskArn"),
                detail.get("group"),
                env_value("OPENCLAW_ALERT_NAME"),
            ]
        )
        state = first_nonempty([detail.get("lastStatus"), detail.get("desiredStatus")])
        message = first_nonempty([detail.get("stoppedReason"), raw.get("message")])
    elif detail_type == "CloudWatch Alarm State Change" or event_source == "aws.cloudwatch":
        event_type = "cloudwatch_alarm_state_change"
        name = first_nonempty([detail.get("alarmName"), raw.get("AlarmName")])
        state = first_nonempty([state_detail.get("value"), raw.get("NewStateValue")])
        message = first_nonempty([state_detail.get("reason"), raw.get("NewStateReason")])
    elif raw.get("AlarmName") or raw.get("NewStateValue"):
        event_type = "cloudwatch_alarm_notification"
        name = raw.get("AlarmName")
        state = raw.get("NewStateValue")
        message = raw.get("NewStateReason")
    elif raw.get("failure") or raw.get("error") or raw.get("error_type"):
        event_type = "agent_failure"
        name = first_nonempty([raw.get("alert_name"), raw.get("task_type"), "agent_failure"])
        state = first_nonempty([raw.get("state"), raw.get("status"), "FAILED"])
        message = first_nonempty([raw.get("message"), raw.get("error"), raw.get("failure")])
    else:
        event_type = "generic_alert"
        name = first_nonempty(
            [
                env_value("OPENCLAW_ALARM_NAME"),
                env_value("OPENCLAW_ALERT_NAME"),
                raw.get("alarm_name"),
                raw.get("alarmName"),
                raw.get("alert_name"),
                raw.get("AlarmName"),
            ]
        )
        state = first_nonempty(
            [
                env_value("OPENCLAW_ALERT_STATE"),
                raw.get("state"),
                raw.get("State"),
                raw.get("NewStateValue"),
            ]
        )
        message = first_nonempty(
            [
                env_value("OPENCLAW_ALERT_MESSAGE"),
                raw.get("message"),
                raw.get("Message"),
                raw.get("NewStateReason"),
            ]
        )

    event_id = first_nonempty(
        [
            raw.get("id"),
            raw.get("event_id"),
            raw.get("MessageId"),
            raw.get("_sns", {}).get("message_id") if isinstance(raw.get("_sns"), Mapping) else None,
        ]
    )
    occurred_at = first_nonempty(
        [
            raw.get("time"),
            raw.get("timestamp"),
            raw.get("StateChangeTime"),
            raw.get("_sns", {}).get("timestamp") if isinstance(raw.get("_sns"), Mapping) else None,
        ]
    )

    return sanitize(
        {
            "event_type": event_type,
            "event_id": event_id,
            "event_source": event_source or raw.get("alert_source") or env_value("OPENCLAW_ALERT_SOURCE") or None,
            "detail_type": detail_type or None,
            "alert_name": str(name).strip() if name else None,
            "alarm_arn": first_nonempty([raw.get("AlarmArn"), raw.get("alarm_arn"), env_value("OPENCLAW_ALARM_ARN")]),
            "state": str(state).strip() if state else None,
            "message": str(message).strip() if message else None,
            "occurred_at": occurred_at,
            "log_group_name": first_nonempty([raw.get("log_group_name"), env_value("OPENCLAW_LOG_GROUP_NAME")]),
            "log_stream_name": first_nonempty([raw.get("log_stream_name"), env_value("OPENCLAW_LOG_STREAM_NAME")]),
            "raw_payload": raw,
        }
    )


def validate_normalized_alert(alert: Mapping[str, Any]) -> List[Dict[str, str]]:
    errors: List[Dict[str, str]] = []
    if not alert.get("alert_name") and not alert.get("message") and not alert.get("event_id"):
        errors.append(
            {
                "code": "alert_context_missing",
                "message": "Alert input must contain an alert name, message, or event identifier.",
            }
        )
    return errors


def build_alert_id(alert: Mapping[str, Any], job_id: str) -> str:
    explicit = env_value("OPENCLAW_ALERT_ID")
    if explicit:
        return explicit
    identity = {
        "event_type": alert.get("event_type"),
        "event_id": alert.get("event_id"),
        "alert_name": alert.get("alert_name"),
        "state": alert.get("state"),
        "occurred_at": alert.get("occurred_at"),
        "message": alert.get("message"),
        "job_id": job_id if not alert.get("event_id") else None,
    }
    return f"alert-{hashlib.sha256(canonical_json(identity).encode('utf-8')).hexdigest()[:32]}"


def check_sts(region: str, client: Any = None) -> Dict[str, Any]:
    try:
        sts = client or boto3.client("sts", region_name=region)
        identity = sts.get_caller_identity()
        return {
            "ok": True,
            "account": identity.get("Account"),
            "arn": identity.get("Arn"),
            "user_id": identity.get("UserId"),
        }
    except Exception as exc:
        return error_result(exc)


def describe_cloudwatch_alarm(region: str, alarm_name: Optional[str], client: Any = None) -> Dict[str, Any]:
    if not alarm_name:
        return {"ok": True, "configured": False, "reason": "alarm name not provided"}
    try:
        cloudwatch = client or boto3.client("cloudwatch", region_name=region)
        response = cloudwatch.describe_alarms(AlarmNames=[alarm_name])
        alarms = response.get("MetricAlarms", []) or response.get("CompositeAlarms", [])
        if not alarms:
            return {
                "ok": False,
                "configured": True,
                "alarm_name": alarm_name,
                "error_type": "AlarmNotFound",
                "error": "alarm_not_found",
            }
        alarm = jsonable(alarms[0])
        safe_alarm = {
            "alarm_name": alarm.get("AlarmName"),
            "alarm_arn": alarm.get("AlarmArn"),
            "state_value": alarm.get("StateValue"),
            "state_reason": alarm.get("StateReason"),
            "state_updated_timestamp": alarm.get("StateUpdatedTimestamp"),
            "namespace": alarm.get("Namespace"),
            "metric_name": alarm.get("MetricName"),
            "dimensions": alarm.get("Dimensions"),
            "comparison_operator": alarm.get("ComparisonOperator"),
            "threshold": alarm.get("Threshold"),
            "evaluation_periods": alarm.get("EvaluationPeriods"),
            "period": alarm.get("Period"),
            "statistic": alarm.get("Statistic"),
            "treat_missing_data": alarm.get("TreatMissingData"),
        }
        return {"ok": True, "configured": True, "alarm": sanitize(safe_alarm)}
    except Exception as exc:
        result = error_result(exc)
        result.update({"configured": True, "alarm_name": alarm_name})
        return result


def collect_recent_log_events(
    region: str,
    log_group_name: Optional[str],
    log_stream_name: Optional[str],
    client: Any = None,
) -> Dict[str, Any]:
    if not log_group_name:
        return {"ok": True, "configured": False, "reason": "log group not provided"}
    try:
        logs = client or boto3.client("logs", region_name=region)
        start_time_ms = int((time.time() - 3600) * 1000)
        if log_stream_name:
            response = logs.get_log_events(
                logGroupName=log_group_name,
                logStreamName=log_stream_name,
                startTime=start_time_ms,
                limit=20,
                startFromHead=False,
            )
            events = response.get("events", [])
        else:
            response = logs.filter_log_events(logGroupName=log_group_name, startTime=start_time_ms, limit=20)
            events = response.get("events", [])

        safe_events = [
            {
                "timestamp": item.get("timestamp"),
                "message": sanitize_text(str(item.get("message", ""))[:1000]),
                "log_stream_name": item.get("logStreamName") or log_stream_name,
            }
            for item in events
        ]
        return {
            "ok": True,
            "configured": True,
            "log_group_name": log_group_name,
            "log_stream_name": log_stream_name,
            "event_count": len(safe_events),
            "events": safe_events,
        }
    except Exception as exc:
        result = error_result(exc)
        result.update(
            {
                "configured": True,
                "log_group_name": log_group_name,
                "log_stream_name": log_stream_name,
            }
        )
        return result


def classify_severity(alert: Mapping[str, Any], alarm_check: Mapping[str, Any]) -> str:
    raw_severity = (
        alert.get("raw_payload", {}).get("severity")
        if isinstance(alert.get("raw_payload"), Mapping)
        else None
    )
    explicit = env_value("OPENCLAW_ALERT_SEVERITY")
    if not explicit and raw_severity not in (None, ""):
        explicit = str(raw_severity)
    if explicit:
        normalized = explicit.strip().lower()
        return normalized if normalized in {"info", "low", "medium", "high", "critical"} else "unknown"

    state = str(alert.get("state") or "").upper()
    name = str(alert.get("alert_name") or "").lower()
    metric = ""
    if alarm_check.get("ok") and alarm_check.get("configured"):
        alarm = alarm_check.get("alarm", {})
        state = str(alarm.get("state_value") or state).upper()
        name = str(alarm.get("alarm_name") or name).lower()
        metric = str(alarm.get("metric_name") or "").lower()

    combined = f"{name} {metric} {str(alert.get('message') or '').lower()}"
    critical_terms = ("panic", "data loss", "security breach", "compromised")
    high_terms = ("error", "fail", "unhealthy", "5xx", "timeout", "throttle", "denied", "oom")
    cost_terms = ("billing", "budget", "cost", "spend")

    if any(term in combined for term in critical_terms):
        return "critical"
    if state in {"STOPPED", "FAILED"} or (state == "ALARM" and any(term in combined for term in high_terms)):
        return "high"
    if state == "ALARM":
        return "medium" if not any(term in combined for term in cost_terms) else "medium"
    if state == "INSUFFICIENT_DATA":
        return "low"
    if state == "OK":
        return "info"
    if any(term in combined for term in high_terms):
        return "medium"
    return "unknown"


def summarize_confirmed_facts(
    alert: Mapping[str, Any], alarm_check: Mapping[str, Any], log_check: Mapping[str, Any]
) -> List[str]:
    facts: List[str] = []
    if alert.get("event_type"):
        facts.append(f"Normalized event type: {alert['event_type']}")
    if alert.get("alert_name"):
        facts.append(f"Alert/alarm name: {alert['alert_name']}")
    if alert.get("state"):
        facts.append(f"Observed state: {alert['state']}")
    if alert.get("message"):
        facts.append(f"Observed message: {str(alert['message'])[:300]}")
    if alarm_check.get("ok") and alarm_check.get("configured"):
        alarm = alarm_check.get("alarm", {})
        if alarm.get("metric_name"):
            facts.append(f"CloudWatch metric: {alarm.get('namespace')}/{alarm.get('metric_name')}")
        if alarm.get("state_value"):
            facts.append(f"CloudWatch current state: {alarm.get('state_value')}")
    if log_check.get("ok") and log_check.get("configured"):
        facts.append(f"Recent log events collected: {log_check.get('event_count', 0)}")
    return facts


def infer_likely_causes(alert: Mapping[str, Any], alarm_check: Mapping[str, Any], log_check: Mapping[str, Any]) -> List[str]:
    text = " ".join(canonical_json(item).lower() for item in (alert, alarm_check, log_check))
    causes: List[str] = []
    rules = (
        (("accessdenied", "not authorized", "unauthorized"), "IAM permission issue or a missing task-role permission may be involved."),
        (("throttl",), "AWS API throttling or a service rate limit may be involved."),
        (("timeout", "timed out"), "A network, service, or dependency timeout may be involved."),
        (("5xx", "server error"), "A downstream service or application endpoint may be returning server-side errors."),
        (("insufficient_data",), "The metric stream may have missing or insufficient datapoints."),
        (("budget", "billing", "cost"), "A cost or budget threshold may have been reached or approached."),
        (("outofmemory", "out of memory", "oom"), "Container memory pressure or an out-of-memory termination may be involved."),
        (("cpu",), "High CPU utilization may be involved."),
    )
    for terms, explanation in rules:
        if any(term in text for term in terms):
            causes.append(explanation)
    return causes or ["The likely cause cannot be determined from the available evidence alone."]


def build_unknowns(alert: Mapping[str, Any], alarm_check: Mapping[str, Any], log_check: Mapping[str, Any]) -> List[str]:
    unknowns: List[str] = []
    if not alert.get("occurred_at"):
        unknowns.append("The event occurrence time was not provided.")
    if not alarm_check.get("configured"):
        unknowns.append("No CloudWatch alarm name was available, so alarm details were not queried.")
    elif not alarm_check.get("ok"):
        unknowns.append("CloudWatch alarm details could not be retrieved.")
    if not log_check.get("configured"):
        unknowns.append("No CloudWatch log group was available, so recent logs were not queried.")
    elif not log_check.get("ok"):
        unknowns.append("Recent CloudWatch log events could not be retrieved.")
    return unknowns


def build_next_checks(severity: str, alarm_check: Mapping[str, Any], log_check: Mapping[str, Any]) -> List[str]:
    checks = [
        "Review the CloudWatch alarm state and state reason.",
        "Check the ECS task exit code, stopped reason, and container logs.",
        "Verify the ECS task role has the minimum required permissions.",
        "Check recent CloudWatch Logs for stack traces, AccessDenied errors, timeouts, or dependency failures.",
    ]
    if severity in {"high", "critical"}:
        checks.extend(
            [
                "Pause further deployment steps until the alert is understood.",
                "Preserve CloudWatch Logs, Step Functions history, and ECS task details as evidence.",
            ]
        )
    if alarm_check.get("ok") and alarm_check.get("configured"):
        metric = str(alarm_check.get("alarm", {}).get("metric_name") or "").lower()
        if "cpu" in metric:
            checks.append("Check ECS task CPU configuration and application CPU usage.")
        if "memory" in metric:
            checks.append("Check ECS task memory configuration and possible OOM termination.")
    if log_check.get("ok") and log_check.get("configured") and log_check.get("event_count") == 0:
        checks.append("Confirm the log group and stream because no recent events were found.")
    return checks


def collect_permission_limitations(checks: Mapping[str, Mapping[str, Any]]) -> List[Dict[str, Any]]:
    limitations: List[Dict[str, Any]] = []
    for name, check in checks.items():
        if check.get("ok") is True:
            continue
        error_text = str(check.get("error") or "")
        code = str(check.get("aws_error_code") or "")
        if code in {"AccessDenied", "AccessDeniedException", "UnauthorizedOperation"} or "not authorized" in error_text.lower():
            limitations.append(
                {
                    "check": name,
                    "aws_error_code": code or None,
                    "message": check.get("aws_error_message") or error_text,
                }
            )
    return limitations


def serialize_dynamodb_item(item: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    serializer = TypeSerializer()
    return {str(key): serializer.serialize(jsonable(value)) for key, value in item.items() if value is not None}


def persist_alert_record(
    region: str,
    table_name: str,
    result: Mapping[str, Any],
    client: Any = None,
) -> Dict[str, Any]:
    if not table_name:
        return {
            "ok": False,
            "enabled": True,
            "error_type": "ConfigurationError",
            "error": "DYNAMODB_ALERTS_TABLE is empty.",
        }
    try:
        dynamodb = client or boto3.client("dynamodb", region_name=region)
        item = {
            "alert_id": result.get("alert_id"),
            "job_id": result.get("job_id"),
            "task_type": result.get("task_type"),
            "event_type": result.get("event_type"),
            "alert_name": result.get("alert_name"),
            "alert_state": result.get("alert_state"),
            "severity": result.get("severity"),
            "human_action_required": result.get("human_action_required"),
            "status": result.get("status"),
            "created_at": result.get("timestamp_utc"),
            "updated_at": now_utc(),
            "payload_sha256": result.get("payload_sha256"),
            "analysis_json": canonical_json(
                {
                    "summary": result.get("summary"),
                    "confirmed_facts": result.get("confirmed_facts"),
                    "likely_causes": result.get("likely_causes"),
                    "unknowns": result.get("unknowns"),
                    "recommended_next_checks": result.get("recommended_next_checks"),
                    "warnings": result.get("warnings"),
                    "errors": result.get("errors"),
                }
            ),
        }
        dynamodb.put_item(TableName=table_name, Item=serialize_dynamodb_item(item))
        return {
            "ok": True,
            "enabled": True,
            "table_name": table_name,
            "alert_id": result.get("alert_id"),
        }
    except Exception as exc:
        response = error_result(exc)
        response.update({"enabled": True, "table_name": table_name})
        return response


def main() -> int:
    region = get_region()
    strict_mode = env_bool("OPENCLAW_ALERT_ANALYSIS_STRICT", False)
    require_payload = env_bool("OPENCLAW_ALERT_REQUIRE_PAYLOAD", True)
    persist_enabled = env_bool("OPENCLAW_ALERT_PERSIST_DYNAMODB", False)

    task_type = env_value("OPENCLAW_TASK_TYPE", "alert_analysis")
    job_id = env_value("OPENCLAW_JOB_ID", "unknown")
    selected_skill = env_value("OPENCLAW_SELECTED_SKILL", "aws-alert-analysis")
    timestamp = now_utc()

    input_result = load_alert_input()
    errors: List[Dict[str, Any]] = []
    warnings: List[str] = []

    if not input_result.get("ok"):
        errors.append(
            {
                "code": "input_parse_failed",
                "message": input_result.get("error"),
                "error_type": input_result.get("error_type"),
            }
        )
        payload: Dict[str, Any] = {}
    else:
        payload = dict(input_result.get("payload") or {})

    normalized = normalize_alert(payload)
    validation_errors = validate_normalized_alert(normalized)
    if require_payload and input_result.get("source") == "empty":
        validation_errors.append(
            {
                "code": "alert_payload_required",
                "message": "No alert payload or fallback alert fields were provided.",
            }
        )
    errors.extend(validation_errors)

    alert_id = build_alert_id(normalized, job_id)
    payload_sha256 = hashlib.sha256(canonical_json(normalized.get("raw_payload", {})).encode("utf-8")).hexdigest()

    alarm_name = normalized.get("alert_name") if "cloudwatch" in str(normalized.get("event_type")) else env_value("OPENCLAW_ALARM_NAME")
    checks: Dict[str, Dict[str, Any]] = {
        "sts_get_caller_identity": check_sts(region),
        "cloudwatch_alarm": describe_cloudwatch_alarm(region, alarm_name),
        "recent_log_events": collect_recent_log_events(
            region,
            normalized.get("log_group_name"),
            normalized.get("log_stream_name"),
        ),
    }

    if strict_mode:
        for check_name, check in checks.items():
            if check.get("configured", True) and not check.get("ok"):
                errors.append(
                    {
                        "code": "required_aws_check_failed",
                        "check": check_name,
                        "message": check.get("error") or check.get("reason") or "AWS check failed.",
                    }
                )

    severity = classify_severity(normalized, checks["cloudwatch_alarm"])
    permission_limitations = collect_permission_limitations(checks)
    if permission_limitations:
        warnings.append("Some read-only AWS checks failed due to permission limitations.")
    if not os.environ.get("DEEPSEEK_API_KEY"):
        warnings.append("DEEPSEEK_API_KEY is not present; this execution used deterministic rule-based analysis only.")

    human_action_required = severity in {"medium", "high", "critical"} or bool(permission_limitations)
    status = "failed" if errors else "success"

    result: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_type": task_type,
        "job_id": job_id,
        "selected_skill": selected_skill,
        "status": status,
        "overall_ok": not errors,
        "timestamp_utc": timestamp,
        "aws_region": region,
        "alert_id": alert_id,
        "payload_sha256": payload_sha256,
        "alert_source": input_result.get("source"),
        "event_type": normalized.get("event_type"),
        "event_id": normalized.get("event_id"),
        "alert_name": normalized.get("alert_name"),
        "alert_state": normalized.get("state"),
        "severity": severity,
        "human_action_required": human_action_required,
        "summary": {
            "text": "Alert analysis completed using the available evidence." if not errors else "Alert analysis could not satisfy the input or strict validation contract.",
            "human_action_required": human_action_required,
        },
        "sanitized_alert_payload": normalized.get("raw_payload", {}),
        "checks": checks,
        "confirmed_facts": summarize_confirmed_facts(normalized, checks["cloudwatch_alarm"], checks["recent_log_events"]),
        "likely_causes": infer_likely_causes(normalized, checks["cloudwatch_alarm"], checks["recent_log_events"]),
        "unknowns": build_unknowns(normalized, checks["cloudwatch_alarm"], checks["recent_log_events"]),
        "recommended_next_checks": build_next_checks(severity, checks["cloudwatch_alarm"], checks["recent_log_events"]),
        "permission_limitations": permission_limitations,
        "warnings": warnings,
        "errors": errors,
        "artifacts": {
            "dynamodb_alert": {"ok": True, "enabled": False},
        },
    }

    if persist_enabled and result["overall_ok"]:
        persistence = persist_alert_record(region, env_value("DYNAMODB_ALERTS_TABLE"), result)
        result["artifacts"]["dynamodb_alert"] = persistence
        if not persistence.get("ok"):
            result["errors"].append(
                {
                    "code": "alert_persistence_failed",
                    "message": persistence.get("error"),
                    "error_type": persistence.get("error_type"),
                    "aws_error_code": persistence.get("aws_error_code"),
                }
            )
            result["status"] = "partial_success"
            result["overall_ok"] = False

    print(json.dumps(jsonable(sanitize(result)), ensure_ascii=False, indent=2))
    return 0 if result["overall_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
