#!/usr/bin/env python3
"""Publish allowlisted OpenClaw-AWS task notifications to Amazon SNS.

The dispatcher runs after a skill finishes. It intentionally receives only the
skill result file and emits a small allowlisted message. Raw alert payloads,
credentials, model prompts, CloudWatch log lines, and arbitrary error messages
are never copied into SNS notifications.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Mapping, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError


SCHEMA_VERSION = "1.0"
TRUE_VALUES = {"1", "true", "yes", "on", "enabled"}
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]+")
SAFE_IDENTIFIER = re.compile(r"[^A-Za-z0-9._:/@+=,-]+")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def env_value(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def env_bool(name: str, default: bool = False) -> bool:
    raw = env_value(name)
    if not raw:
        return default
    return raw.lower() in TRUE_VALUES


def safe_identifier(value: Any, default: str = "unknown", max_length: int = 200) -> str:
    text = str(value or "").strip()
    if not text:
        return default
    text = CONTROL_CHARACTERS.sub(" ", text)
    text = SAFE_IDENTIFIER.sub("_", text)
    return text[:max_length] or default


def safe_subject(value: str) -> str:
    text = CONTROL_CHARACTERS.sub(" ", value).strip()
    text = " ".join(text.split())
    return text[:100] or "OpenClaw-AWS notification"


def normalize_task_type(value: Any) -> str:
    task_type = safe_identifier(value, "unknown").lower().replace("-", "_")
    aliases = {
        "aws_alert_analysis": "alert_analysis",
        "aws_report_generation": "report_generation",
        "aws_daily_inspection": "daily_inspection",
        "aws_cost_inspection": "cost_inspection",
        "aws_task_healthcheck": "healthcheck",
        "task_healthcheck": "healthcheck",
    }
    return aliases.get(task_type, task_type)


def load_result(path: str) -> Dict[str, Any]:
    if not path:
        return {}
    result_path = Path(path)
    if not result_path.is_file():
        return {}
    try:
        value = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"result file is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("result file must contain a JSON object")
    return value


def _safe_s3_uri(value: Any) -> Optional[str]:
    text = str(value or "").strip()
    if not text.startswith("s3://"):
        return None
    return safe_identifier(text, max_length=1000)


def _error_codes(result: Mapping[str, Any]) -> list[str]:
    codes: list[str] = []
    errors = result.get("errors")
    if not isinstance(errors, list):
        return codes
    for item in errors[:10]:
        if isinstance(item, Mapping) and item.get("code"):
            codes.append(safe_identifier(item.get("code"), max_length=80))
    return codes


def build_notification(
    result: Mapping[str, Any],
    exit_code: int,
    environment: Optional[Mapping[str, str]] = None,
) -> Optional[Dict[str, Any]]:
    env = environment or os.environ
    task_type = normalize_task_type(result.get("task_type") or env.get("OPENCLAW_TASK_TYPE"))
    job_id = safe_identifier(result.get("job_id") or env.get("OPENCLAW_JOB_ID"), "unknown-job")
    status = safe_identifier(
        result.get("status") or ("failed" if exit_code else "success"),
        "unknown",
        80,
    )
    overall_ok = bool(result.get("overall_ok", exit_code == 0)) and exit_code == 0

    base: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "project": "OpenClaw-AWS",
        "environment": safe_identifier(env.get("OPENCLAW_ENVIRONMENT", "dev"), "dev", 40),
        "job_id": job_id,
        "task_type": task_type,
        "status": status,
        "overall_ok": overall_ok,
        "task_exit_code": int(exit_code),
        "timestamp_utc": safe_identifier(result.get("timestamp_utc") or utc_now(), max_length=80),
        "notification_source": "ecs-task-dispatcher",
    }

    if exit_code != 0 or not overall_ok:
        base.update(
            {
                "event_type": "task_failed",
                "error_codes": _error_codes(result),
                "message": "OpenClaw-AWS task execution did not complete successfully.",
            }
        )
        return {
            "subject": safe_subject(f"OpenClaw-AWS task failed: {task_type}"),
            "message": base,
        }

    if task_type == "alert_analysis":
        severity = safe_identifier(result.get("severity"), "unknown", 40)
        base.update(
            {
                "event_type": "alert_analysis_completed",
                "alert_id": safe_identifier(result.get("alert_id"), "unknown-alert"),
                "severity": severity,
                "human_action_required": bool(result.get("human_action_required", False)),
                "message": "OpenClaw-AWS alert analysis completed.",
            }
        )
        return {
            "subject": safe_subject(f"OpenClaw-AWS alert {severity}: {status}"),
            "message": base,
        }

    if task_type == "report_generation":
        s3_artifacts = result.get("artifacts", {}).get("s3", {}) if isinstance(result.get("artifacts"), Mapping) else {}
        if not isinstance(s3_artifacts, Mapping):
            s3_artifacts = {}
        base.update(
            {
                "event_type": "report_generation_completed",
                "report_id": safe_identifier(result.get("report_id"), "unknown-report"),
                "source_task_type": normalize_task_type(result.get("source_task_type")),
                "markdown_s3_uri": _safe_s3_uri(s3_artifacts.get("markdown_uri")),
                "summary_s3_uri": _safe_s3_uri(s3_artifacts.get("summary_uri")),
                "message": "OpenClaw-AWS report generation completed.",
            }
        )
        return {
            "subject": safe_subject(f"OpenClaw-AWS report ready: {status}"),
            "message": base,
        }

    return None


def publish_notification(
    topic_arn: str,
    notification: Mapping[str, Any],
    region: str,
    client: Any = None,
) -> Dict[str, Any]:
    if not topic_arn:
        return {
            "ok": False,
            "published": False,
            "error_type": "ConfigurationError",
            "error": "SNS_TOPIC_ARN is empty",
        }

    sns = client or boto3.client("sns", region_name=region)
    message = notification.get("message")
    if not isinstance(message, Mapping):
        return {
            "ok": False,
            "published": False,
            "error_type": "ConfigurationError",
            "error": "notification message must be an object",
        }

    event_type = safe_identifier(message.get("event_type"), "unknown", 80)
    task_type = safe_identifier(message.get("task_type"), "unknown", 80)
    status = safe_identifier(message.get("status"), "unknown", 80)

    try:
        response = sns.publish(
            TopicArn=topic_arn,
            Subject=safe_subject(str(notification.get("subject") or "OpenClaw-AWS notification")),
            Message=json.dumps(message, ensure_ascii=False, sort_keys=True),
            MessageAttributes={
                "event_type": {"DataType": "String", "StringValue": event_type},
                "task_type": {"DataType": "String", "StringValue": task_type},
                "status": {"DataType": "String", "StringValue": status},
            },
        )
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        error: Dict[str, Any] = {
            "ok": False,
            "published": False,
            "error_type": type(exc).__name__,
            "error": str(exc),
            "event_type": event_type,
        }
        if isinstance(exc, ClientError):
            error["aws_error_code"] = exc.response.get("Error", {}).get("Code")
        return error

    return {
        "ok": True,
        "published": True,
        "message_id": response.get("MessageId"),
        "event_type": event_type,
        "topic_arn_sha256": hashlib.sha256(topic_arn.encode("utf-8")).hexdigest(),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-file", default=env_value("OPENCLAW_RESULT_FILE"))
    parser.add_argument("--exit-code", type=int, default=0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not env_bool("OPENCLAW_SNS_NOTIFY_ENABLED", False):
        print(json.dumps({"ok": True, "published": False, "reason": "notifications_disabled"}))
        return 0

    try:
        result = load_result(args.result_file)
        notification = build_notification(result, args.exit_code)
    except ValueError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "published": False,
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                }
            ),
            file=sys.stderr,
        )
        return 1

    if notification is None:
        print(json.dumps({"ok": True, "published": False, "reason": "task_not_notifiable"}))
        return 0

    outcome = publish_notification(
        env_value("SNS_TOPIC_ARN"),
        notification,
        env_value("AWS_REGION", env_value("AWS_DEFAULT_REGION", "ap-northeast-1")),
    )
    stream = sys.stdout if outcome.get("ok") else sys.stderr
    print(json.dumps(outcome, ensure_ascii=False, sort_keys=True), file=stream)
    return 0 if outcome.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
