#!/usr/bin/env python3
"""Sanitized EFS-backed task history for OpenClaw-AWS.

The store keeps one immutable JSON document per completed task. It intentionally
avoids a shared mutable index so concurrent Fargate tasks cannot corrupt each
other's history. Report generation can later read a bounded recent window and
build a deterministic aggregate payload.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

SCHEMA_VERSION = "1.0"
DEFAULT_HISTORY_DIR = "/app/runtime/history"
DEFAULT_TASK_TYPES = ("alert_analysis", "daily_inspection", "cost_inspection")
DEFAULT_MAX_FILE_BYTES = 262_144
DEFAULT_RETENTION_DAYS = 30
DEFAULT_LOOKBACK_HOURS = 168
DEFAULT_MAX_ITEMS = 100

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

# Explicitly exclude raw or high-risk fields even after redaction. The history
# layer is for reporting metadata, not for preserving complete source events.
HISTORY_ALLOWLIST = (
    "schema_version",
    "task_type",
    "job_id",
    "selected_skill",
    "status",
    "overall_ok",
    "timestamp_utc",
    "aws_region",
    "alert_id",
    "event_type",
    "event_id",
    "alert_name",
    "alert_state",
    "severity",
    "human_action_required",
    "summary",
    "checks",
    "confirmed_facts",
    "likely_causes",
    "unknowns",
    "recommended_next_checks",
    "recommendations",
    "permission_limitations",
    "warnings",
    "errors",
    "cost_risks",
)


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def isoformat_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "enabled"}


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def parse_task_types(value: Optional[str]) -> Tuple[str, ...]:
    raw = value if value is not None else os.environ.get("OPENCLAW_EFS_HISTORY_TASK_TYPES", "")
    values = [item.strip() for item in raw.split(",") if item.strip()]
    return tuple(dict.fromkeys(values or DEFAULT_TASK_TYPES))


def sanitize_text(value: str) -> str:
    result = value
    result = SENSITIVE_VALUE_PATTERNS[0].sub("Bearer ***REDACTED***", result)
    result = SENSITIVE_VALUE_PATTERNS[1].sub("***REDACTED_AWS_ACCESS_KEY***", result)
    result = SENSITIVE_VALUE_PATTERNS[2].sub(
        lambda match: f"{match.group(1)}=***REDACTED***", result
    )
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
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def safe_segment(value: Any, fallback: str) -> str:
    text = str(value or "")
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-._")
    return (cleaned or fallback)[:120]


def parse_timestamp(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def read_json_object(path: Path, max_file_bytes: int) -> Dict[str, Any]:
    if path.is_symlink():
        raise ValueError(f"Refusing symlink: {path}")
    if not path.exists():
        raise FileNotFoundError(f"Result file not found: {path}")
    if not path.is_file():
        raise ValueError(f"Path is not a regular file: {path}")
    size = path.stat().st_size
    if size <= 0:
        raise ValueError(f"JSON file is empty: {path}")
    if size > max_file_bytes:
        raise ValueError(f"JSON file exceeds {max_file_bytes} bytes: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, Mapping):
        raise ValueError(f"JSON value must be an object: {path}")
    return dict(value)


def compact_value(
    value: Any,
    depth: int = 0,
    max_depth: int = 6,
    max_string_chars: int = 2000,
    max_list_items: int = 50,
    max_mapping_items: int = 100,
) -> Any:
    if depth >= max_depth:
        return "***TRUNCATED_DEPTH***"
    if isinstance(value, str):
        return value if len(value) <= max_string_chars else value[:max_string_chars] + "...TRUNCATED..."
    if isinstance(value, Mapping):
        result: Dict[str, Any] = {}
        for index, (key, item) in enumerate(value.items()):
            if index >= max_mapping_items:
                result["__truncated_items__"] = len(value) - max_mapping_items
                break
            result[str(key)] = compact_value(
                item,
                depth + 1,
                max_depth,
                max_string_chars,
                max_list_items,
                max_mapping_items,
            )
        return result
    if isinstance(value, (list, tuple, set)):
        values = list(value)
        result = [
            compact_value(
                item,
                depth + 1,
                max_depth,
                max_string_chars,
                max_list_items,
                max_mapping_items,
            )
            for item in values[:max_list_items]
        ]
        if len(values) > max_list_items:
            result.append({"__truncated_items__": len(values) - max_list_items})
        return result
    return value


def compact_checks(value: Any) -> Any:
    if not isinstance(value, Mapping):
        return {}
    allowed_fields = (
        "ok",
        "configured",
        "reason",
        "error_type",
        "aws_error_code",
        "event_count",
    )
    checks: Dict[str, Any] = {}
    for name, check in value.items():
        if isinstance(check, Mapping):
            checks[str(name)] = {
                field: compact_value(sanitize(check[field]))
                for field in allowed_fields
                if field in check
            }
        else:
            checks[str(name)] = {"ok": None}
    return checks


def extract_last_json_object(text: str) -> Dict[str, Any]:
    decoder = json.JSONDecoder()
    candidates: List[Tuple[int, int, int, Dict[str, Any]]] = []
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            value, end = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if not isinstance(value, Mapping):
            continue
        value_dict = dict(value)
        marker_score = sum(
            weight
            for key, weight in (
                ("task_type", 100),
                ("job_id", 50),
                ("overall_ok", 25),
                ("status", 20),
                ("schema_version", 10),
            )
            if key in value_dict
        )
        candidates.append((marker_score, end, index, value_dict))

    if not candidates:
        raise ValueError("No JSON object was found in the captured skill output")

    # Task-result markers outrank nested objects. Object span then favors the
    # complete outer result, while source position favors the latest result if
    # a runner printed more than one complete task object.
    _, _, _, selected = max(
        candidates,
        key=lambda item: (item[0], item[1], item[2]),
    )
    return selected


def capture_result_file(source_file: Path, output_file: Path, max_file_bytes: int) -> Dict[str, Any]:
    if source_file.is_symlink():
        raise ValueError(f"Refusing symlink: {source_file}")
    if not source_file.exists() or not source_file.is_file():
        raise FileNotFoundError(f"Captured skill output not found: {source_file}")
    if source_file.stat().st_size > max_file_bytes:
        raise ValueError(f"Captured skill output exceeds {max_file_bytes} bytes: {source_file}")
    result = extract_last_json_object(source_file.read_text(encoding="utf-8", errors="replace"))
    atomic_write_json(output_file, sanitize(result))
    return {
        "ok": True,
        "captured": True,
        "result_file": str(output_file),
        "task_type": result.get("task_type"),
        "job_id": result.get("job_id"),
    }


def build_history_record(
    result: Mapping[str, Any],
    exit_code: int,
    archived_at: Optional[datetime] = None,
) -> Dict[str, Any]:
    sanitized = sanitize(dict(result))
    selected: Dict[str, Any] = {}
    for key in HISTORY_ALLOWLIST:
        if key not in sanitized:
            continue
        selected[key] = (
            compact_checks(sanitized[key])
            if key == "checks"
            else compact_value(sanitized[key])
        )

    archived = archived_at or now_utc()
    source_hash = hashlib.sha256(canonical_json(sanitized).encode("utf-8")).hexdigest()

    record: Dict[str, Any] = {
        "history_schema_version": SCHEMA_VERSION,
        "archived_at": isoformat_utc(archived),
        "source_result_sha256": source_hash,
        "task_exit_code": int(exit_code),
        **selected,
    }
    record["task_type"] = str(record.get("task_type") or "unknown")
    record["job_id"] = str(record.get("job_id") or "unknown")
    record["status"] = str(record.get("status") or ("success" if exit_code == 0 else "failed"))
    record["overall_ok"] = bool(record.get("overall_ok", exit_code == 0))
    return record


def atomic_write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def prune_history(history_dir: Path, retention_days: int, reference: Optional[datetime] = None) -> int:
    if not history_dir.exists():
        return 0
    cutoff = (reference or now_utc()).timestamp() - retention_days * 86_400
    deleted = 0
    for path in history_dir.rglob("*.json"):
        try:
            if path.is_symlink() or not path.is_file():
                continue
            if path.stat().st_mtime < cutoff:
                path.unlink()
                deleted += 1
        except FileNotFoundError:
            continue
    for directory in sorted(
        (path for path in history_dir.rglob("*") if path.is_dir()),
        key=lambda item: len(item.parts),
        reverse=True,
    ):
        try:
            directory.rmdir()
        except OSError:
            pass
    return deleted


def archive_result(
    result_file: Path,
    history_dir: Path,
    exit_code: int,
    task_types: Sequence[str],
    max_file_bytes: int = DEFAULT_MAX_FILE_BYTES,
    retention_days: int = DEFAULT_RETENTION_DAYS,
    archived_at: Optional[datetime] = None,
) -> Dict[str, Any]:
    result = read_json_object(result_file, max_file_bytes)
    task_type = str(result.get("task_type") or os.environ.get("OPENCLAW_TASK_TYPE") or "unknown")

    if task_type == "report_generation":
        return {"ok": True, "archived": False, "reason": "report_generation_excluded"}
    if task_type not in set(task_types):
        return {
            "ok": True,
            "archived": False,
            "reason": "task_type_not_enabled",
            "task_type": task_type,
        }

    archived = archived_at or now_utc()
    record = build_history_record(result, exit_code, archived)
    event_time = parse_timestamp(record.get("timestamp_utc")) or archived
    date_path = event_time.strftime("%Y/%m/%d")
    filename = "{}-{}-{}.json".format(
        event_time.strftime("%Y%m%dT%H%M%S%fZ"),
        safe_segment(record.get("job_id"), "unknown-job"),
        record["source_result_sha256"][:12],
    )
    destination = history_dir / date_path / safe_segment(task_type, "unknown-task") / filename

    record_size = len((json.dumps(record, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    if record_size > max_file_bytes:
        raise ValueError(
            f"Sanitized history record exceeds {max_file_bytes} bytes after compaction"
        )

    already_exists = destination.exists()
    if not already_exists:
        atomic_write_json(destination, record)

    pruned = prune_history(history_dir, retention_days, archived)
    return {
        "ok": True,
        "archived": True,
        "already_exists": already_exists,
        "task_type": task_type,
        "job_id": record.get("job_id"),
        "history_file": str(destination),
        "source_result_sha256": record["source_result_sha256"],
        "pruned_files": pruned,
    }


def record_time(record: Mapping[str, Any], path: Path) -> datetime:
    for name in ("timestamp_utc", "archived_at"):
        parsed = parse_timestamp(record.get(name))
        if parsed is not None:
            return parsed
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)


def read_recent_history(
    history_dir: Path,
    lookback_hours: int = DEFAULT_LOOKBACK_HOURS,
    max_items: int = DEFAULT_MAX_ITEMS,
    task_types: Sequence[str] = DEFAULT_TASK_TYPES,
    max_file_bytes: int = DEFAULT_MAX_FILE_BYTES,
    reference: Optional[datetime] = None,
) -> Dict[str, Any]:
    current = reference or now_utc()
    cutoff = current - timedelta(hours=lookback_hours)
    allowed = set(task_types)
    candidates: List[Tuple[datetime, Path, Dict[str, Any]]] = []
    skipped_invalid = 0
    skipped_old = 0
    skipped_task_type = 0

    if history_dir.exists():
        for path in history_dir.rglob("*.json"):
            try:
                record = read_json_object(path, max_file_bytes)
                if record.get("history_schema_version") != SCHEMA_VERSION:
                    raise ValueError(f"Unsupported or missing history schema: {path}")
                task_type = str(record.get("task_type") or "unknown")
                if task_type not in allowed:
                    skipped_task_type += 1
                    continue
                timestamp = record_time(record, path)
                if timestamp < cutoff or timestamp > current + timedelta(minutes=5):
                    skipped_old += 1
                    continue
                candidates.append((timestamp, path, sanitize(record)))
            except (OSError, ValueError, json.JSONDecodeError):
                skipped_invalid += 1

    candidates.sort(key=lambda item: (item[0], str(item[1])), reverse=True)
    selected = candidates[:max_items]
    records = [item[2] for item in selected]

    return {
        "ok": True,
        "history_dir": str(history_dir),
        "lookback_hours": lookback_hours,
        "max_items": max_items,
        "candidate_count": len(candidates),
        "included_count": len(records),
        "truncated_count": max(0, len(candidates) - len(records)),
        "skipped_invalid": skipped_invalid,
        "skipped_old": skipped_old,
        "skipped_task_type": skipped_task_type,
        "task_types": list(task_types),
        "window_start": isoformat_utc(cutoff),
        "window_end": isoformat_utc(current),
        "records": records,
    }


def values_as_list(record: Mapping[str, Any], *names: str) -> List[Any]:
    for name in names:
        value = record.get(name)
        if isinstance(value, list):
            return value
        if value not in (None, ""):
            return [value]
    return []


def unique_values(values: Iterable[Any], maximum: int) -> List[Any]:
    result: List[Any] = []
    seen = set()
    for value in values:
        marker = canonical_json(value)
        if marker in seen:
            continue
        seen.add(marker)
        result.append(value)
        if len(result) >= maximum:
            break
    return result


def build_aggregate_payload(history: Mapping[str, Any]) -> Dict[str, Any]:
    records = history.get("records") if isinstance(history.get("records"), list) else []
    warnings: List[Any] = []
    recommendations: List[Any] = []
    cost_risks: List[Any] = []
    errors: List[Dict[str, Any]] = []
    record_summaries: List[Dict[str, Any]] = []
    task_type_counts: Counter[str] = Counter()
    status_counts: Counter[str] = Counter()
    severity_counts: Counter[str] = Counter()

    for record in records:
        if not isinstance(record, Mapping):
            continue
        task_type = str(record.get("task_type") or "unknown")
        status = str(record.get("status") or "unknown")
        severity = str(record.get("severity") or "unknown")
        task_type_counts[task_type] += 1
        status_counts[status] += 1
        severity_counts[severity] += 1

        warnings.extend(values_as_list(record, "warnings"))
        recommendations.extend(
            values_as_list(record, "recommendations", "recommended_next_checks")
        )
        cost_risks.extend(values_as_list(record, "cost_risks"))

        record_errors = values_as_list(record, "errors")
        if record.get("overall_ok") is False and not record_errors:
            record_errors = [
                {
                    "code": "source_task_failed",
                    "message": "The archived source task reported overall_ok=false.",
                }
            ]
        for error in record_errors:
            if isinstance(error, Mapping):
                errors.append(
                    {
                        "check": task_type,
                        "error": error.get("code") or error.get("error") or "source_error",
                        "message": error.get("message") or error.get("error"),
                        "job_id": record.get("job_id"),
                    }
                )
            else:
                errors.append(
                    {
                        "check": task_type,
                        "error": "source_error",
                        "message": error,
                        "job_id": record.get("job_id"),
                    }
                )

        record_summaries.append(
            {
                "task_type": task_type,
                "job_id": record.get("job_id"),
                "timestamp_utc": record.get("timestamp_utc") or record.get("archived_at"),
                "status": status,
                "overall_ok": record.get("overall_ok"),
                "severity": record.get("severity"),
                "human_action_required": record.get("human_action_required"),
                "summary": record.get("summary"),
                "alert_id": record.get("alert_id"),
                "event_type": record.get("event_type"),
            }
        )

    return {
        "task_type": "efs_history_aggregate",
        "source_task_type": "efs_history",
        "overall_ok": not errors,
        "warnings": unique_values(warnings, 200),
        "errors": unique_values(errors, 200),
        "recommendations": unique_values(recommendations, 200),
        "cost_risks": unique_values(cost_risks, 200),
        "checks": {
            "efs_history": {
                "ok": bool(records),
                "included_count": len(records),
                "candidate_count": history.get("candidate_count", 0),
                "truncated_count": history.get("truncated_count", 0),
                "skipped_invalid": history.get("skipped_invalid", 0),
            }
        },
        "aggregation": {
            "history_dir": history.get("history_dir"),
            "window_start": history.get("window_start"),
            "window_end": history.get("window_end"),
            "lookback_hours": history.get("lookback_hours"),
            "included_count": len(records),
            "task_type_counts": dict(sorted(task_type_counts.items())),
            "status_counts": dict(sorted(status_counts.items())),
            "severity_counts": dict(sorted(severity_counts.items())),
        },
        "history_records": record_summaries,
    }


def archive_from_environment(result_file: Path, exit_code: int) -> Dict[str, Any]:
    return archive_result(
        result_file=result_file,
        history_dir=Path(os.environ.get("OPENCLAW_EFS_HISTORY_DIR", DEFAULT_HISTORY_DIR)),
        exit_code=exit_code,
        task_types=parse_task_types(None),
        max_file_bytes=env_int(
            "OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES", DEFAULT_MAX_FILE_BYTES, 4_096, 1_048_576
        ),
        retention_days=env_int(
            "OPENCLAW_EFS_HISTORY_RETENTION_DAYS", DEFAULT_RETENTION_DAYS, 1, 365
        ),
    )


def recent_history_from_environment() -> Dict[str, Any]:
    return read_recent_history(
        history_dir=Path(os.environ.get("OPENCLAW_EFS_HISTORY_DIR", DEFAULT_HISTORY_DIR)),
        lookback_hours=env_int(
            "OPENCLAW_REPORT_EFS_LOOKBACK_HOURS", DEFAULT_LOOKBACK_HOURS, 1, 2_160
        ),
        max_items=env_int("OPENCLAW_REPORT_EFS_MAX_ITEMS", DEFAULT_MAX_ITEMS, 1, 500),
        task_types=parse_task_types(None),
        max_file_bytes=env_int(
            "OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES", DEFAULT_MAX_FILE_BYTES, 4_096, 1_048_576
        ),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenClaw-AWS EFS history store")
    subparsers = parser.add_subparsers(dest="command", required=True)

    archive = subparsers.add_parser("archive", help="Archive one sanitized task result")
    archive.add_argument("--result-file", required=True)
    archive.add_argument("--exit-code", required=True, type=int)

    capture = subparsers.add_parser(
        "capture", help="Extract the last JSON object from captured skill output"
    )
    capture.add_argument("--source-file", required=True)
    capture.add_argument("--output-file", required=True)

    aggregate = subparsers.add_parser("aggregate", help="Read and aggregate recent history")
    aggregate.add_argument("--history-dir")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "archive":
            result = archive_from_environment(Path(args.result_file), args.exit_code)
        elif args.command == "capture":
            result = capture_result_file(
                Path(args.source_file),
                Path(args.output_file),
                env_int(
                    "OPENCLAW_RESULT_CAPTURE_MAX_BYTES",
                    1_048_576,
                    4_096,
                    4_194_304,
                ),
            )
        else:
            if args.history_dir:
                os.environ["OPENCLAW_EFS_HISTORY_DIR"] = args.history_dir
            history = recent_history_from_environment()
            result = {
                "history": {key: value for key, value in history.items() if key != "records"},
                "payload": build_aggregate_payload(history),
            }
        print(json.dumps(sanitize(result), ensure_ascii=False, sort_keys=True))
        return 0
    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error_type": exc.__class__.__name__,
                    "error": sanitize_text(str(exc)),
                },
                ensure_ascii=False,
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
