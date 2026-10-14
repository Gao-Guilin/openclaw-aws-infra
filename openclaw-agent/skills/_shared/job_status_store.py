#!/usr/bin/env python3
"""Maintain the DynamoDB Jobs lifecycle for OpenClaw ECS tasks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError


NON_TERMINAL_STATUSES = {
    "PENDING",
    "RECEIVED",
    "DISPATCHING",
    "QUEUED",
    "RUNNING",
}

TERMINAL_STATUSES = {
    "SUCCEEDED",
    "FAILED",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def target_status(exit_code: int) -> str:
    return "SUCCEEDED" if exit_code == 0 else "FAILED"


def truncate_text(value: str | None, limit: int = 1000) -> str | None:
    if value is None:
        return None

    normalized = " ".join(str(value).split())

    if not normalized:
        return None

    return normalized[:limit]


def read_result_metadata(result_file: str | None) -> dict[str, Any]:
    if not result_file:
        return {}

    path = Path(result_file)

    if not path.is_file():
        return {}

    metadata: dict[str, Any] = {}

    try:
        metadata["result_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return {}

    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return metadata

    if not isinstance(raw, dict):
        return metadata

    if raw.get("status") is not None:
        metadata["result_status"] = str(raw["status"])[:100]

    if isinstance(raw.get("overall_ok"), bool):
        metadata["result_overall_ok"] = raw["overall_ok"]

    for key in ("fatal_error", "error", "message", "detail"):
        candidate = truncate_text(
            None if raw.get(key) is None else str(raw.get(key))
        )

        if candidate:
            metadata["result_error"] = candidate
            break

    return metadata


def get_job_state(
    client: Any,
    table_name: str,
    job_id: str,
) -> tuple[bool, str | None]:
    response = client.get_item(
        TableName=table_name,
        Key={"job_id": {"S": job_id}},
        ConsistentRead=True,
        ProjectionExpression="#job_id, #job_status",
        ExpressionAttributeNames={
            "#job_id": "job_id",
            "#job_status": "status",
        },
    )

    item = response.get("Item")

    if not item:
        return False, None

    status_value = item.get("status", {}).get("S")

    if status_value is None:
        return True, None

    return True, str(status_value).upper()


def condition_values(
    allowed_statuses: set[str],
) -> tuple[str, dict[str, dict[str, str]]]:
    placeholders: list[str] = []
    values: dict[str, dict[str, str]] = {}

    for index, status in enumerate(sorted(allowed_statuses)):
        placeholder = f":allowed_status_{index}"
        placeholders.append(placeholder)
        values[placeholder] = {"S": status}

    condition = (
        "attribute_exists(#job_id) AND "
        "(attribute_not_exists(#job_status) OR "
        f"#job_status IN ({', '.join(placeholders)}))"
    )

    return condition, values


def mark_running(
    client: Any,
    table_name: str,
    job_id: str,
    now: str | None = None,
) -> dict[str, Any]:
    exists, current_status = get_job_state(client, table_name, job_id)

    if not exists:
        return {
            "ok": True,
            "updated": False,
            "reason": "job_not_found",
            "job_id": job_id,
        }

    if current_status in TERMINAL_STATUSES:
        return {
            "ok": False,
            "updated": False,
            "reason": "terminal_status_conflict",
            "job_id": job_id,
            "current_status": current_status,
            "requested_status": "RUNNING",
        }

    timestamp = now or utc_now()
    condition, allowed_values = condition_values(NON_TERMINAL_STATUSES)

    expression_values: dict[str, dict[str, Any]] = {
        ":running": {"S": "RUNNING"},
        ":timestamp": {"S": timestamp},
        ":status_source": {"S": "ecs-agent"},
        **allowed_values,
    }

    try:
        response = client.update_item(
            TableName=table_name,
            Key={"job_id": {"S": job_id}},
            UpdateExpression=(
                "SET #job_status = :running, "
                "updated_at = :timestamp, "
                "started_at = if_not_exists(started_at, :timestamp), "
                "status_source = :status_source"
            ),
            ConditionExpression=condition,
            ExpressionAttributeNames={
                "#job_id": "job_id",
                "#job_status": "status",
            },
            ExpressionAttributeValues=expression_values,
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "ClientError")

        if error_code == "ConditionalCheckFailedException":
            return {
                "ok": False,
                "updated": False,
                "reason": "conditional_status_conflict",
                "job_id": job_id,
                "requested_status": "RUNNING",
            }

        raise

    return {
        "ok": True,
        "updated": True,
        "job_id": job_id,
        "status": "RUNNING",
        "attributes": response.get("Attributes", {}),
    }


def mark_finished(
    client: Any,
    table_name: str,
    job_id: str,
    exit_code: int,
    result_file: str | None = None,
    error_message: str | None = None,
    failure_stage: str | None = None,
    now: str | None = None,
) -> dict[str, Any]:
    exists, current_status = get_job_state(client, table_name, job_id)
    requested_status = target_status(exit_code)

    if not exists:
        return {
            "ok": True,
            "updated": False,
            "reason": "job_not_found",
            "job_id": job_id,
            "requested_status": requested_status,
        }

    if current_status == requested_status:
        return {
            "ok": True,
            "updated": False,
            "reason": "already_in_requested_terminal_status",
            "job_id": job_id,
            "status": requested_status,
        }

    if current_status in TERMINAL_STATUSES:
        return {
            "ok": False,
            "updated": False,
            "reason": "terminal_status_conflict",
            "job_id": job_id,
            "current_status": current_status,
            "requested_status": requested_status,
        }

    timestamp = now or utc_now()
    allowed_statuses = set(NON_TERMINAL_STATUSES)
    allowed_statuses.add(requested_status)

    condition, allowed_values = condition_values(allowed_statuses)

    expression_names = {
        "#job_id": "job_id",
        "#job_status": "status",
    }

    expression_values: dict[str, dict[str, Any]] = {
        ":requested_status": {"S": requested_status},
        ":timestamp": {"S": timestamp},
        ":exit_code": {"N": str(exit_code)},
        ":completion_source": {"S": "ecs-agent"},
        **allowed_values,
    }

    set_parts = [
        "#job_status = :requested_status",
        "updated_at = :timestamp",
        "completed_at = if_not_exists(completed_at, :timestamp)",
        "exit_code = :exit_code",
        "completion_source = :completion_source",
    ]

    remove_parts: list[str] = []
    result_metadata = read_result_metadata(result_file)

    if result_metadata.get("result_sha256"):
        expression_values[":result_sha256"] = {
            "S": str(result_metadata["result_sha256"])
        }
        set_parts.append("result_sha256 = :result_sha256")

    if result_metadata.get("result_status"):
        expression_values[":result_status"] = {
            "S": str(result_metadata["result_status"])
        }
        set_parts.append("result_status = :result_status")

    if isinstance(result_metadata.get("result_overall_ok"), bool):
        expression_values[":result_overall_ok"] = {
            "BOOL": result_metadata["result_overall_ok"]
        }
        set_parts.append("result_overall_ok = :result_overall_ok")

    if requested_status == "FAILED":
        resolved_error = truncate_text(
            error_message or result_metadata.get("result_error")
        )

        if resolved_error:
            expression_values[":error_message"] = {"S": resolved_error}
            set_parts.append("error_message = :error_message")

        resolved_stage = truncate_text(failure_stage, limit=100)

        if resolved_stage:
            expression_values[":failure_stage"] = {"S": resolved_stage}
            set_parts.append("failure_stage = :failure_stage")
    else:
        remove_parts.extend([
            "error_message",
            "error_type",
            "failure_stage",
        ])

    update_expression = "SET " + ", ".join(set_parts)

    if remove_parts:
        update_expression += " REMOVE " + ", ".join(remove_parts)

    try:
        response = client.update_item(
            TableName=table_name,
            Key={"job_id": {"S": job_id}},
            UpdateExpression=update_expression,
            ConditionExpression=condition,
            ExpressionAttributeNames=expression_names,
            ExpressionAttributeValues=expression_values,
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "ClientError")

        if error_code == "ConditionalCheckFailedException":
            return {
                "ok": False,
                "updated": False,
                "reason": "conditional_status_conflict",
                "job_id": job_id,
                "requested_status": requested_status,
            }

        raise

    return {
        "ok": True,
        "updated": True,
        "job_id": job_id,
        "status": requested_status,
        "exit_code": exit_code,
        "attributes": response.get("Attributes", {}),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Update an existing OpenClaw Jobs lifecycle record."
    )

    parser.add_argument(
        "action",
        choices=("start", "finish"),
    )

    parser.add_argument(
        "--table-name",
        default=os.environ.get("DYNAMODB_JOBS_TABLE"),
    )

    parser.add_argument(
        "--job-id",
        default=os.environ.get("OPENCLAW_JOB_ID"),
    )

    parser.add_argument(
        "--region",
        default=(
            os.environ.get("AWS_REGION")
            or os.environ.get("AWS_DEFAULT_REGION")
            or "ap-northeast-1"
        ),
    )

    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--result-file")
    parser.add_argument("--error-message")
    parser.add_argument("--failure-stage")

    return parser


def main() -> int:
    args = build_parser().parse_args()

    if not args.table_name:
        print(
            json.dumps({
                "ok": False,
                "reason": "table_name_missing",
            }),
            file=sys.stderr,
        )
        return 2

    if not args.job_id:
        print(
            json.dumps({
                "ok": False,
                "reason": "job_id_missing",
            }),
            file=sys.stderr,
        )
        return 2

    if args.action == "finish" and args.exit_code is None:
        print(
            json.dumps({
                "ok": False,
                "reason": "exit_code_missing",
            }),
            file=sys.stderr,
        )
        return 2

    client = boto3.client("dynamodb", region_name=args.region)

    try:
        if args.action == "start":
            result = mark_running(
                client=client,
                table_name=args.table_name,
                job_id=args.job_id,
            )
        else:
            result = mark_finished(
                client=client,
                table_name=args.table_name,
                job_id=args.job_id,
                exit_code=args.exit_code,
                result_file=args.result_file,
                error_message=args.error_message,
                failure_stage=args.failure_stage,
            )
    except (BotoCoreError, ClientError) as exc:
        print(
            json.dumps({
                "ok": False,
                "reason": "aws_error",
                "error_type": type(exc).__name__,
                "detail": truncate_text(str(exc), limit=1000),
                "job_id": args.job_id,
            }),
            file=sys.stderr,
        )
        return 2

    print(json.dumps(result, ensure_ascii=False))

    return 0 if result.get("ok") else 3


if __name__ == "__main__":
    raise SystemExit(main())
