#!/usr/bin/env python3
"""OpenClaw-AWS report generation skill.

The source skills remain the authority for operational facts. This module:
1. loads and sanitizes a source result,
2. chooses deterministic-template vs bounded LLM presentation,
3. renders a fixed Chinese Markdown report,
4. writes a compact JSON summary,
5. optionally uploads both artifacts to S3,
6. optionally writes a DynamoDB report index.

No infrastructure remediation is performed here.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple

try:
    import boto3
    from boto3.dynamodb.types import TypeSerializer
    from botocore.exceptions import ClientError
except Exception as exc:  # pragma: no cover - broken image only
    print(
        json.dumps(
            {
                "schema_version": "2.0",
                "task_type": "report_generation",
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


SKILL_DIR = Path(__file__).resolve().parent
if str(SKILL_DIR) not in sys.path:
    sys.path.insert(0, str(SKILL_DIR))

SHARED_SKILLS_DIR = Path(__file__).resolve().parents[1] / "_shared"
if str(SHARED_SKILLS_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_SKILLS_DIR))

from efs_history_store import build_aggregate_payload, recent_history_from_environment  # noqa: E402
from report_summarizer import summarize_with_openclaw  # noqa: E402


SCHEMA_VERSION = "2.0"
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

TASK_ALIASES = {
    "healthcheck": "healthcheck",
    "task-healthcheck": "healthcheck",
    "task_healthcheck": "healthcheck",
    "aws-task-healthcheck": "healthcheck",
    "aws_task_healthcheck": "healthcheck",
    "daily_inspection": "daily_inspection",
    "daily-inspection": "daily_inspection",
    "aws-daily-inspection": "daily_inspection",
    "aws_daily_inspection": "daily_inspection",
    "cost_inspection": "cost_inspection",
    "cost-inspection": "cost_inspection",
    "aws-cost-inspection": "cost_inspection",
    "aws_cost_inspection": "cost_inspection",
    "alert_analysis": "alert_analysis",
    "alert-analysis": "alert_analysis",
    "aws-alert-analysis": "alert_analysis",
    "aws_alert_analysis": "alert_analysis",
    "efs_history": "efs_history",
    "efs_history_aggregate": "efs_history",
}

TASK_SKILL_NAMES = {
    "healthcheck": "aws-task-healthcheck",
    "daily_inspection": "aws-daily-inspection",
    "cost_inspection": "aws-cost-inspection",
    "alert_analysis": "aws-alert-analysis",
    "efs_history": "aws-report-generation",
}

TASK_TITLES = {
    "healthcheck": "OpenClaw-AWS 健康检查报告",
    "daily_inspection": "OpenClaw-AWS 日常巡检报告",
    "cost_inspection": "OpenClaw-AWS 成本巡检报告",
    "alert_analysis": "OpenClaw-AWS 告警分析报告",
    "efs_history": "OpenClaw-AWS 综合运行报告",
}

TASK_DISPLAY_NAMES = {
    "healthcheck": "健康检查",
    "daily_inspection": "日常巡检",
    "cost_inspection": "成本巡检",
    "alert_analysis": "告警分析",
    "efs_history": "综合运行汇总",
}

CHECK_LABELS = {
    "environment": "运行环境",
    "openclaw_home": "OpenClaw Home 目录",
    "runtime_dir": "Runtime 运行目录",
    "workspace": "Workspace 工作目录",
    "openclaw_config_json": "OpenClaw 配置文件",
    "openclaw_cli": "OpenClaw CLI",
    "prompt_file": "任务 Prompt 文件",
    "sts_get_caller_identity": "AWS STS 身份认证",
    "cloudwatch_list_metrics": "CloudWatch ListMetrics API",
    "ecs_task_metadata": "ECS Task Metadata",
    "cloudwatch_metrics": "CloudWatch 指标可见性",
    "cloudwatch_alarms": "CloudWatch 告警状态",
    "cloudwatch_log_groups": "CloudWatch Logs 日志组",
    "s3_report_bucket": "S3 报告 Bucket",
    "dynamodb_jobs_table": "DynamoDB Jobs 表",
    "sqs_queue": "SQS 队列",
    "sns_topic": "SNS Topic",
    "efs_file_system": "EFS 文件系统",
    "efs_file_systems": "EFS 文件系统",
    "ecs_cluster": "ECS Cluster",
    "cost_explorer": "AWS Cost Explorer",
    "budgets": "AWS Budgets",
    "cloudwatch_log_cost_risk": "CloudWatch Logs 成本风险",
    "nat_gateways": "NAT Gateway",
    "cloudwatch_alarm": "CloudWatch Alarm",
    "recent_log_events": "最近 CloudWatch Logs",
}


# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

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
        result: Dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            if any(keyword in key_text.lower() for keyword in SENSITIVE_KEYWORDS):
                result[key_text] = "***REDACTED***"
            else:
                result[key_text] = sanitize(item)
        return result
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


def safe_filename(value: str, fallback: str) -> str:
    cleaned = "".join(char if char.isalnum() or char in {"-", "_", "."} else "-" for char in value)
    return cleaned.strip("-._") or fallback


def normalize_task_type(value: str) -> str:
    raw = (value or "").strip().lower()
    return TASK_ALIASES.get(raw, raw.replace("-", "_") or "unknown")


def source_skill_name(source_task_type: str, payload: Mapping[str, Any]) -> str:
    explicit = env_value("OPENCLAW_SOURCE_SKILL")
    if explicit:
        return safe_filename(explicit, "unknown-skill")
    selected = payload.get("selected_skill")
    if isinstance(selected, str) and selected.strip() and selected != "aws-report-generation":
        return safe_filename(selected, "unknown-skill")
    return TASK_SKILL_NAMES.get(normalize_task_type(source_task_type), safe_filename(source_task_type, "unknown-skill"))


def source_environment(payload: Mapping[str, Any]) -> str:
    explicit = env_value("OPENCLAW_ENVIRONMENT")
    if explicit:
        return safe_filename(explicit.lower(), "unknown")
    value = payload.get("environment")
    if isinstance(value, str) and value.strip():
        return safe_filename(value.lower(), "unknown")
    return "unknown"


def parse_timestamp(value: Any, fallback: Optional[str] = None) -> datetime:
    text = str(value or fallback or now_utc()).strip()
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        parsed = datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return datetime.now(timezone.utc)


def artifact_time_parts(payload: Mapping[str, Any], generated_at: str) -> Tuple[str, str, str, str]:
    dt = parse_timestamp(payload.get("timestamp_utc"), generated_at)
    return dt.strftime("%Y"), dt.strftime("%m"), dt.strftime("%d"), dt.strftime("%Y%m%dT%H%M%SZ")


def build_artifact_basename(
    payload: Mapping[str, Any],
    source_task_type: str,
    job_id: str,
    generated_at: str,
) -> str:
    skill = source_skill_name(source_task_type, payload)
    _, _, _, timestamp = artifact_time_parts(payload, generated_at)
    return safe_filename(f"{skill}_{timestamp}_{job_id}", "openclaw-report")


# ---------------------------------------------------------------------------
# Input and source-result interpretation
# ---------------------------------------------------------------------------

def load_input_payload() -> Dict[str, Any]:
    raw_json = env_value("OPENCLAW_REPORT_INPUT_JSON")
    input_file = env_value("OPENCLAW_REPORT_INPUT_FILE")

    try:
        if raw_json:
            payload = json.loads(raw_json)
            source = "OPENCLAW_REPORT_INPUT_JSON"
        elif input_file:
            target = Path(input_file)
            if not target.exists():
                raise FileNotFoundError(f"Input file not found: {input_file}")
            if not target.is_file():
                raise ValueError(f"Input path is not a file: {input_file}")
            text = target.read_text(encoding="utf-8")
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                payload = {"raw_text": text}
            source = "OPENCLAW_REPORT_INPUT_FILE"
        else:
            if env_bool("OPENCLAW_REPORT_EFS_AGGREGATE", True):
                history = recent_history_from_environment()
                if history.get("included_count", 0) > 0:
                    return {
                        "ok": True,
                        "source": "EFS_HISTORY",
                        "payload": sanitize(build_aggregate_payload(history)),
                        "history": {
                            "enabled": True,
                            **{key: value for key, value in history.items() if key != "records"},
                        },
                    }
                return {
                    "ok": True,
                    "source": "empty",
                    "payload": {},
                    "history": {
                        "enabled": True,
                        **{key: value for key, value in history.items() if key != "records"},
                    },
                }
            return {"ok": True, "source": "empty", "payload": {}}

        if not isinstance(payload, Mapping):
            payload = {"value": payload}
        return {"ok": True, "source": source, "payload": sanitize(dict(payload))}
    except Exception as exc:
        result = error_result(exc)
        result.update(
            {
                "source": (
                    "OPENCLAW_REPORT_INPUT_FILE"
                    if input_file
                    else "OPENCLAW_REPORT_INPUT_JSON"
                    if raw_json
                    else "EFS_HISTORY"
                )
            }
        )
        return result


def extract_source_task_type(payload: Mapping[str, Any]) -> str:
    value = env_value("OPENCLAW_SOURCE_TASK_TYPE") or payload.get("source_task_type") or payload.get("task_type")
    return str(value or "unknown")


def extract_list(payload: Mapping[str, Any], *names: str) -> List[Any]:
    for name in names:
        value = payload.get(name)
        if isinstance(value, list):
            return value
        if value is not None and value != "":
            return [value]
    return []


def extract_failures(payload: Mapping[str, Any]) -> List[Dict[str, Any]]:
    failures: List[Dict[str, Any]] = []
    checks = payload.get("checks")
    if isinstance(checks, Mapping):
        for name, check in checks.items():
            if isinstance(check, Mapping) and check.get("ok") is False:
                failures.append(
                    {
                        "check": name,
                        "error": check.get("error"),
                        "error_type": check.get("error_type"),
                        "aws_error_code": check.get("aws_error_code"),
                        "message": check.get("aws_error_message") or check.get("reason"),
                    }
                )
    for item in extract_list(payload, "permission_limitations"):
        failures.append(
            {
                "check": item.get("check") if isinstance(item, Mapping) else "permission_limitation",
                "error": "permission_limitation",
                "message": item,
            }
        )
    for item in extract_list(payload, "errors"):
        failures.append(
            {
                "check": item.get("check") if isinstance(item, Mapping) else "source_task",
                "error": item.get("code") if isinstance(item, Mapping) else "source_error",
                "message": item.get("message") if isinstance(item, Mapping) else item,
            }
        )
    if payload.get("overall_ok") is False and not failures:
        failures.append(
            {
                "check": "source_task",
                "error": "source_task_failed",
                "message": "The source task reported overall_ok=false.",
            }
        )
    return failures


def build_report_id(payload: Mapping[str, Any], source_task_type: str, job_id: str) -> str:
    explicit = env_value("OPENCLAW_REPORT_ID")
    if explicit:
        return explicit

    identity_payload: Any = json.loads(canonical_json(payload))
    if normalize_task_type(source_task_type) == "efs_history" and isinstance(identity_payload, Mapping):
        identity_payload = dict(identity_payload)
        aggregation = identity_payload.get("aggregation")
        if isinstance(aggregation, Mapping):
            stable_aggregation = dict(aggregation)
            for volatile_key in ("history_dir", "window_start", "window_end"):
                stable_aggregation.pop(volatile_key, None)
            identity_payload["aggregation"] = stable_aggregation

    identity = {
        "job_id": job_id,
        "source_task_type": source_task_type,
        "payload": identity_payload,
    }
    return f"report-{hashlib.sha256(canonical_json(identity).encode('utf-8')).hexdigest()[:32]}"


def failed_check_count(payload: Mapping[str, Any]) -> int:
    checks = payload.get("checks")
    if not isinstance(checks, Mapping):
        return 0
    return sum(1 for check in checks.values() if isinstance(check, Mapping) and check.get("ok") is False)


# ---------------------------------------------------------------------------
# Template vs LLM routing
# ---------------------------------------------------------------------------

def select_summary_route(payload: Mapping[str, Any], source_task_type: str) -> str:
    """Return template, llm_flash, or llm_pro."""
    override = env_value("OPENCLAW_REPORT_SUMMARY_MODE", "auto").strip().lower()
    if override in {"template", "llm_flash", "llm_pro"}:
        return override
    if override not in {"", "auto"}:
        raise ValueError(f"Unsupported OPENCLAW_REPORT_SUMMARY_MODE: {override}")

    task = normalize_task_type(source_task_type)
    warnings = extract_list(payload, "warnings")
    permission_limitations = extract_list(payload, "permission_limitations")
    errors = extract_list(payload, "errors")
    failures = failed_check_count(payload)

    if task == "healthcheck":
        if payload.get("overall_ok") is True and not warnings and failures == 0:
            return "template"
        return "llm_flash"

    if task == "daily_inspection":
        if payload.get("overall_ok") is True and not warnings and not permission_limitations and failures == 0:
            return "template"
        return "llm_flash"

    if task == "cost_inspection":
        cost_risks = extract_list(payload, "cost_risks")
        if payload.get("overall_ok") is True and not cost_risks and not permission_limitations and failures == 0:
            return "template"
        if len(cost_risks) >= 3 or failures >= 2 or len(permission_limitations) >= 2:
            return "llm_pro"
        return "llm_flash"

    if task == "alert_analysis":
        severity = str(payload.get("severity") or "unknown").lower()
        if severity in {"info", "low"} and not errors and not permission_limitations:
            return "template"
        if severity in {"high", "critical"}:
            return "llm_pro"
        return "llm_flash"

    if task == "efs_history":
        return "llm_pro"

    return "llm_flash" if warnings or failures or errors else "template"


def _cn_bool(value: Any) -> str:
    if value is True:
        return "正常"
    if value is False:
        return "异常"
    return "未知"


def _as_text(item: Any) -> str:
    if isinstance(item, Mapping):
        for key in ("message", "error", "reason", "code", "check"):
            value = item.get(key)
            if value not in (None, ""):
                return sanitize_text(str(value))
        return json.dumps(sanitize(item), ensure_ascii=False, sort_keys=True)
    return sanitize_text(str(item))


def _join_cn(items: Iterable[Any], limit: int = 5) -> str:
    values = [_as_text(item) for item in items]
    values = [value for value in values if value]
    if not values:
        return "无"
    shown = values[:limit]
    suffix = f"；另有 {len(values) - limit} 项" if len(values) > limit else ""
    return "；".join(shown) + suffix


def build_template_presentation(payload: Mapping[str, Any], source_task_type: str) -> Dict[str, Any]:
    task = normalize_task_type(source_task_type)
    display = TASK_DISPLAY_NAMES.get(task, source_task_type)
    overall_ok = payload.get("overall_ok") is True
    warnings = extract_list(payload, "warnings")
    failures = extract_failures(payload)
    permission_limitations = extract_list(payload, "permission_limitations")
    cost_risks = extract_list(payload, "cost_risks")

    if task == "alert_analysis":
        severity = str(payload.get("severity") or "unknown").upper()
        facts = extract_list(payload, "confirmed_facts")
        executive = (
            f"本次{display}已完成，当前严重级别为 {severity}。"
            f"已确认事实共 {len(facts)} 项，系统保留了可能原因、未知项和后续检查建议，"
            "用于人工继续判断。"
        )
        likely = extract_list(payload, "likely_causes")
        unknowns = extract_list(payload, "unknowns")
        risk = (
            f"当前可能原因：{_join_cn(likely)}。"
            f" 当前仍存在的未知项：{_join_cn(unknowns)}。"
            "可能原因仅为假设，不能视为已确认根因。"
        )
        actions = [_as_text(item) for item in extract_list(payload, "recommended_next_checks")]
        return {
            "executive_summary": executive,
            "risk_explanation": risk,
            "recommended_actions": [item for item in actions if item],
        }

    if overall_ok:
        executive = f"本次{display}已完成，源任务总体结果正常。"
    else:
        executive = f"本次{display}已完成，但源任务总体结果存在异常，需要结合失败检查项继续处理。"

    if warnings:
        executive += f" 本次记录到 {len(warnings)} 项警告。"
    if failures:
        executive += f" 共发现 {len(failures)} 项失败或限制记录。"
    if cost_risks:
        executive += f" 共识别 {len(cost_risks)} 项成本风险。"

    if cost_risks:
        risk = f"本次发现的成本风险包括：{_join_cn(cost_risks)}。"
    elif failures or permission_limitations:
        risk = (
            "当前存在失败检查项或可见性限制，报告只能基于已经取得的证据给出结论；"
            "未成功读取的项目不能被视为正常。"
        )
    elif warnings:
        risk = "当前存在非阻塞性警告，建议结合详细检查结果确认是否需要后续处理。"
    else:
        risk = "当前未发现需要立即处理的明显风险。"

    actions = [_as_text(item) for item in extract_list(payload, "recommendations", "recommended_next_checks")]
    if not actions:
        if overall_ok and not warnings and not failures and not cost_risks:
            actions = ["当前无需立即处理，继续保持现有监控和定期检查即可。"]
        else:
            actions = ["优先核对失败检查项和警告对应的原始证据，再决定是否需要变更。"]

    return {
        "executive_summary": executive,
        "risk_explanation": risk,
        "recommended_actions": [item for item in actions if item],
    }


def build_presentation(payload: Mapping[str, Any], source_task_type: str) -> Dict[str, Any]:
    route = select_summary_route(payload, source_task_type)
    fallback = build_template_presentation(payload, source_task_type)

    if route == "template":
        return {
            **fallback,
            "summary_mode": "template",
            "model_used": None,
            "provider": None,
            "llm_error": None,
        }

    if not os.environ.get("DEEPSEEK_API_KEY"):
        return {
            **fallback,
            "summary_mode": "fallback_template",
            "model_used": None,
            "provider": None,
            "llm_error": "DEEPSEEK_API_KEY is not available",
        }

    tier = "pro" if route == "llm_pro" else "flash"
    try:
        llm = summarize_with_openclaw(
            payload,
            source_task_type,
            tier,
            prompt_path=env_value("OPENCLAW_REPORT_PROMPT_PATH") or env_value("OPENCLAW_PROMPT_PATH"),
            config_path=env_value("OPENCLAW_CONFIG_PATH", "/home/node/.openclaw/openclaw.json"),
            workspace=env_value("OPENCLAW_WORKSPACE", "/app/runtime/workspace"),
            timeout_seconds=int(env_value("OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS", "120")),
        )
        return {
            "executive_summary": llm["executive_summary"],
            "risk_explanation": llm["risk_explanation"],
            "recommended_actions": llm["recommended_actions"],
            "summary_mode": route,
            "model_used": llm.get("model_used"),
            "provider": llm.get("provider"),
            "llm_error": None,
        }
    except Exception as exc:
        return {
            **fallback,
            "summary_mode": "fallback_template",
            "model_used": None,
            "provider": None,
            "llm_error": sanitize_text(str(exc))[:2000],
        }


# ---------------------------------------------------------------------------
# Chinese report rendering
# ---------------------------------------------------------------------------

def check_label(name: str) -> str:
    return CHECK_LABELS.get(name, name)


def _notable_check_details(check: Mapping[str, Any]) -> List[str]:
    details: List[str] = []
    fields = (
        ("account", "Account"),
        ("arn", "ARN"),
        ("state", "状态"),
        ("state_value", "状态"),
        ("metric_count", "指标数量"),
        ("alarm_count", "告警数量"),
        ("log_group_count", "日志组数量"),
        ("message_count", "消息数量"),
        ("approximate_number_of_messages", "可见消息数"),
        ("approximate_number_of_messages_not_visible", "处理中消息数"),
        ("service_count", "Service 数量"),
        ("running_tasks_count", "运行任务数"),
        ("pending_tasks_count", "等待任务数"),
        ("size_in_bytes", "大小(bytes)"),
        ("billing_mode", "计费模式"),
    )
    for key, label in fields:
        if key in check and check.get(key) not in (None, "", [], {}):
            details.append(f"{label}={sanitize_text(str(check.get(key)))}")
    return details[:5]


def render_check_lines(checks: Mapping[str, Any]) -> List[str]:
    lines: List[str] = []
    for name, raw in checks.items():
        label = check_label(str(name))
        if not isinstance(raw, Mapping):
            lines.append(f"- **{label}**：已返回结果，但结果格式不是标准检查对象。")
            continue
        if raw.get("configured") is False:
            lines.append(f"- **{label}**：本次未配置或未提供对应资源，未执行实际检查。")
            continue
        ok = raw.get("ok")
        if ok is True:
            detail = _notable_check_details(raw)
            suffix = f"（{'；'.join(detail)}）" if detail else ""
            lines.append(f"- **{label}**：正常{suffix}。")
        elif ok is False:
            message = raw.get("aws_error_message") or raw.get("error") or raw.get("reason") or "未提供详细错误信息"
            error_type = raw.get("aws_error_code") or raw.get("error_type")
            prefix = f"{error_type}：" if error_type else ""
            lines.append(f"- **{label}**：未通过。{prefix}{sanitize_text(str(message))}")
        else:
            lines.append(f"- **{label}**：状态未知。")
    return lines or ["- 本次结果中没有结构化 checks 字段。"]


def render_scope_lines(source_task_type: str, checks: Mapping[str, Any]) -> List[str]:
    task = normalize_task_type(source_task_type)
    if task == "alert_analysis":
        return [
            "- 标准化告警/事件上下文；",
            "- 核对 CloudWatch Alarm 与可用日志证据；",
            "- 区分已确认事实、可能原因和未知项；",
            "- 给出需要人工执行的下一步检查建议。",
        ]
    if checks:
        return [f"- {check_label(str(name))}" for name in checks.keys()]
    if task == "efs_history":
        return ["- 汇总最近 EFS History 中的任务运行记录、状态、警告和建议。"]
    return ["- 本次源结果未提供可枚举的检查项。"]


def render_issue_lines(
    payload: Mapping[str, Any],
    warnings: List[Any],
    failures: List[Dict[str, Any]],
    cost_risks: List[Any],
) -> List[str]:
    lines: List[str] = []
    for item in warnings:
        lines.append(f"- **警告**：{_as_text(item)}")
    for item in extract_list(payload, "permission_limitations"):
        lines.append(f"- **权限/可见性限制**：{_as_text(item)}")
    for item in failures:
        check = check_label(str(item.get("check") or "source_task"))
        message = item.get("message") or item.get("error") or "检查未通过"
        lines.append(f"- **{check}**：{_as_text(message)}")
    for item in cost_risks:
        lines.append(f"- **成本风险**：{_as_text(item)}")
    for item in extract_list(payload, "unknowns"):
        lines.append(f"- **未知项**：{_as_text(item)}")
    if not lines:
        lines.append("- 本次未发现需要单独记录的异常、警告或限制。")
    return lines


def dedupe_actions(*groups: Iterable[Any]) -> List[str]:
    result: List[str] = []
    seen = set()
    for group in groups:
        for item in group:
            text = _as_text(item).strip()
            if not text or text in seen:
                continue
            seen.add(text)
            result.append(text)
    return result


def build_evidence_payload(payload: Mapping[str, Any], source_task_type: str) -> Dict[str, Any]:
    task = normalize_task_type(source_task_type)
    evidence: Dict[str, Any] = {
        "task_type": payload.get("task_type") or source_task_type,
        "job_id": payload.get("job_id"),
        "timestamp_utc": payload.get("timestamp_utc"),
        "aws_region": payload.get("aws_region"),
        "overall_ok": payload.get("overall_ok"),
    }
    if task == "alert_analysis":
        evidence.update(
            {
                "severity": payload.get("severity"),
                "alert_name": payload.get("alert_name"),
                "alert_state": payload.get("alert_state"),
                "confirmed_facts": payload.get("confirmed_facts", []),
                "likely_causes": payload.get("likely_causes", []),
                "unknowns": payload.get("unknowns", []),
            }
        )
    elif task == "cost_inspection":
        evidence["cost_risks"] = payload.get("cost_risks", [])
    return sanitize(evidence)


def build_markdown(
    payload: Mapping[str, Any],
    source: str,
    source_task_type: str,
    source_skill: str,
    job_id: str,
    report_id: str,
    region: str,
    environment: str,
    generated_at: str,
    report_status: str,
    presentation: Mapping[str, Any],
    warnings: List[Any],
    failures: List[Dict[str, Any]],
    recommendations: List[Any],
    cost_risks: List[Any],
    checks: Mapping[str, Any],
) -> str:
    task = normalize_task_type(source_task_type)
    title = env_value("OPENCLAW_REPORT_TITLE") or TASK_TITLES.get(task, f"OpenClaw-AWS {source_task_type} 报告")
    source_time = str(payload.get("timestamp_utc") or generated_at)
    source_overall = payload.get("overall_ok")

    scope_lines = render_scope_lines(source_task_type, checks)
    result_lines = render_check_lines(checks)

    if task == "alert_analysis":
        result_lines.extend(
            ["", "### 已确认事实"]
            + [f"- {_as_text(item)}" for item in extract_list(payload, "confirmed_facts")]
        )
        likely = extract_list(payload, "likely_causes")
        if likely:
            result_lines.extend(["", "### 可能原因（尚未确认）"] + [f"- {_as_text(item)}" for item in likely])

    issue_lines = render_issue_lines(payload, warnings, failures, cost_risks)
    actions = dedupe_actions(
        recommendations,
        extract_list(payload, "recommended_next_checks"),
        presentation.get("recommended_actions", []) if isinstance(presentation.get("recommended_actions"), list) else [],
    )
    if not actions:
        actions = ["当前无需立即处理，继续保持现有监控并按计划执行下一次检查。"]

    evidence_json = json.dumps(build_evidence_payload(payload, source_task_type), ensure_ascii=False, indent=2)

    lines = [
        f"# {title}",
        "",
        "## 一、检查结论",
        "",
        str(presentation.get("executive_summary") or "本次任务已完成。"),
        "",
        f"源任务最终判断：**{_cn_bool(source_overall)}**。",
        "",
        "## 二、本次检查内容",
        "",
        *scope_lines,
        "",
        "## 三、检查结果",
        "",
        *result_lines,
        "",
        "## 四、发现的问题、警告与限制",
        "",
        *issue_lines,
        "",
        "## 五、风险说明",
        "",
        str(presentation.get("risk_explanation") or "当前未生成额外风险说明。"),
        "",
        "## 六、建议",
        "",
        *[f"- {item}" for item in actions],
        "",
        "## 七、任务信息",
        "",
        f"- Source Skill：`{source_skill}`",
        f"- Source Task Type：`{source_task_type}`",
        f"- Job ID：`{job_id}`",
        f"- Environment：`{environment}`",
        f"- AWS Region：`{region}`",
        f"- 源任务执行时间：`{source_time}`",
        f"- 报告生成时间：`{generated_at}`",
        f"- 报告生成方式：`{presentation.get('summary_mode')}`",
        f"- 使用模型：`{presentation.get('model_used') or 'none'}`",
        f"- Report ID：`{report_id}`",
        f"- Report Status：`{report_status}`",
        f"- Input Source：`{source}`",
        "",
        "## 八、结构化证据摘要",
        "",
        "```json",
        evidence_json,
        "```",
        "",
        "---",
        "",
        "说明：源 Skill 的结构化结果是事实来源；大模型仅用于中文解释和建议，不负责改写源任务的健康状态、严重级别或已确认事实。",
    ]

    if presentation.get("llm_error"):
        lines.extend(
            [
                "",
                f"> LLM 总结未完成，已自动降级为固定模板。原因：{sanitize_text(str(presentation.get('llm_error')))}",
            ]
        )

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Artifact persistence
# ---------------------------------------------------------------------------

def write_markdown(report_dir: Path, artifact_basename: str, markdown: str) -> Dict[str, Any]:
    try:
        report_dir.mkdir(parents=True, exist_ok=True)
        path = report_dir / f"{safe_filename(artifact_basename, 'report')}.md"
        path.write_text(markdown, encoding="utf-8")
        return {"ok": True, "path": str(path), "size_bytes": path.stat().st_size}
    except Exception as exc:
        return error_result(exc)


def write_summary(summary_path: Path, summary: Mapping[str, Any]) -> Dict[str, Any]:
    try:
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        summary_path.write_text(json.dumps(jsonable(sanitize(summary)), ensure_ascii=False, indent=2), encoding="utf-8")
        return {"ok": True, "path": str(summary_path), "size_bytes": summary_path.stat().st_size}
    except Exception as exc:
        return error_result(exc)


def build_s3_locations(
    bucket: str,
    prefix: str,
    environment: str,
    source_skill: str,
    artifact_basename: str,
    payload: Optional[Mapping[str, Any]] = None,
    generated_at: Optional[str] = None,
) -> Dict[str, str]:
    normalized_prefix = prefix.strip("/") or "reports"
    env_segment = safe_filename(environment or "unknown", "unknown")
    skill_segment = safe_filename(source_skill or "unknown-skill", "unknown-skill")
    payload = payload or {}
    year, month, day, _ = artifact_time_parts(payload, generated_at or now_utc())
    base_key = (
        f"{normalized_prefix}/{env_segment}/{skill_segment}/{year}/{month}/{day}/"
        f"{safe_filename(artifact_basename, 'report')}"
    )
    return {
        "markdown_key": f"{base_key}.md",
        "summary_key": f"{base_key}.summary.json",
        "markdown_uri": f"s3://{bucket}/{base_key}.md",
        "summary_uri": f"s3://{bucket}/{base_key}.summary.json",
    }


def put_s3_object(
    region: str,
    bucket: str,
    key: str,
    body: bytes,
    content_type: str,
    client: Any = None,
) -> Dict[str, Any]:
    try:
        s3 = client or boto3.client("s3", region_name=region)
        response = s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType=content_type)
        return {"ok": True, "etag": response.get("ETag"), "version_id": response.get("VersionId")}
    except Exception as exc:
        return error_result(exc)


def serialize_dynamodb_item(item: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    serializer = TypeSerializer()
    return {str(key): serializer.serialize(jsonable(value)) for key, value in item.items() if value is not None}


def write_report_index(
    region: str,
    table_name: str,
    summary: Mapping[str, Any],
    client: Any = None,
) -> Dict[str, Any]:
    if not table_name:
        return {
            "ok": False,
            "enabled": True,
            "error_type": "ConfigurationError",
            "error": "DYNAMODB_REPORTS_TABLE is empty.",
        }
    try:
        dynamodb = client or boto3.client("dynamodb", region_name=region)
        artifacts = summary.get("artifacts", {}) if isinstance(summary.get("artifacts"), Mapping) else {}
        s3_artifacts = artifacts.get("s3", {}) if isinstance(artifacts.get("s3"), Mapping) else {}
        item = {
            "report_id": summary.get("report_id"),
            "job_id": summary.get("job_id"),
            "task_type": summary.get("task_type"),
            "source_task_type": summary.get("source_task_type"),
            "source_skill": summary.get("source_skill"),
            "source_overall_ok": summary.get("source_overall_ok"),
            "status": summary.get("status"),
            "report_status": summary.get("report_status"),
            "summary_mode": summary.get("summary_mode"),
            "model_used": summary.get("model_used"),
            "created_at": summary.get("timestamp_utc"),
            "updated_at": now_utc(),
            "markdown_sha256": summary.get("markdown_sha256"),
            "markdown_s3_uri": s3_artifacts.get("markdown_uri"),
            "summary_s3_uri": s3_artifacts.get("summary_uri"),
            "warning_count": summary.get("warning_count"),
            "failure_count": summary.get("failure_count"),
            "cost_risk_count": summary.get("cost_risk_count"),
        }
        dynamodb.put_item(TableName=table_name, Item=serialize_dynamodb_item(item))
        return {
            "ok": True,
            "enabled": True,
            "table_name": table_name,
            "report_id": summary.get("report_id"),
        }
    except Exception as exc:
        result = error_result(exc)
        result.update({"enabled": True, "table_name": table_name})
        return result


def determine_report_status(
    input_ok: bool,
    source: str,
    require_input: bool,
    warnings: List[Any],
    failures: List[Dict[str, Any]],
    cost_risks: List[Any],
) -> str:
    if not input_ok:
        return "input_error"
    if require_input and source == "empty":
        return "input_required_but_missing"
    if failures:
        return "generated_with_failures"
    if warnings or cost_risks:
        return "generated_with_warnings"
    return "generated"


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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    region = get_region()
    require_input = env_bool("OPENCLAW_REPORT_REQUIRE_INPUT", True)
    upload_s3_enabled = env_bool("OPENCLAW_REPORT_UPLOAD_S3", False)
    write_index_enabled = env_bool("OPENCLAW_REPORT_WRITE_INDEX", False)

    task_type = env_value("OPENCLAW_TASK_TYPE", "report_generation")
    job_id = env_value("OPENCLAW_JOB_ID", "unknown")
    selected_skill = env_value("OPENCLAW_SELECTED_SKILL", "aws-report-generation")
    generated_at = now_utc()

    input_result = load_input_payload()
    payload: Dict[str, Any] = dict(input_result.get("payload") or {}) if input_result.get("ok") else {}
    source = str(input_result.get("source") or "unknown")
    source_task_type = extract_source_task_type(payload)
    normalized_source_task = normalize_task_type(source_task_type)
    source_skill = source_skill_name(source_task_type, payload)
    environment = source_environment(payload)
    report_id = build_report_id(payload, source_task_type, job_id)
    artifact_basename = build_artifact_basename(payload, source_task_type, job_id, generated_at)

    warnings = extract_list(payload, "warnings")
    recommendations = extract_list(payload, "recommendations", "recommended_next_checks")
    failures = extract_failures(payload)
    cost_risks = extract_list(payload, "cost_risks")
    checks = payload.get("checks", {}) if isinstance(payload.get("checks"), Mapping) else {}
    errors: List[Dict[str, Any]] = []

    if not input_result.get("ok"):
        errors.append(
            {
                "code": "input_parse_failed",
                "message": input_result.get("error"),
                "error_type": input_result.get("error_type"),
            }
        )
    if require_input and source == "empty":
        errors.append({"code": "report_input_required", "message": "No report input was provided."})

    sts_check = check_sts(region)
    account_id = str(sts_check.get("account") or "") if sts_check.get("ok") else ""
    report_status = determine_report_status(
        bool(input_result.get("ok")), source, require_input, warnings, failures, cost_risks
    )

    try:
        presentation = build_presentation(payload, source_task_type)
    except Exception as exc:
        fallback = build_template_presentation(payload, source_task_type)
        presentation = {
            **fallback,
            "summary_mode": "fallback_template",
            "model_used": None,
            "provider": None,
            "llm_error": sanitize_text(str(exc))[:2000],
        }

    markdown = build_markdown(
        payload,
        source,
        source_task_type,
        source_skill,
        job_id,
        report_id,
        region,
        environment,
        generated_at,
        report_status,
        presentation,
        warnings,
        failures,
        recommendations,
        cost_risks,
        checks,
    )
    markdown_sha256 = hashlib.sha256(markdown.encode("utf-8")).hexdigest()

    report_dir = Path(env_value("OPENCLAW_REPORT_DIR") or f"{env_value('OPENCLAW_RUNTIME_DIR', '/app/runtime')}/reports")
    markdown_write = write_markdown(report_dir, artifact_basename, markdown)
    summary_path = report_dir / f"{safe_filename(artifact_basename, 'report')}.summary.json"
    if not markdown_write.get("ok"):
        errors.append(
            {
                "code": "local_markdown_write_failed",
                "message": markdown_write.get("error"),
                "error_type": markdown_write.get("error_type"),
            }
        )

    s3_artifacts: Dict[str, Any] = {"ok": True, "enabled": False}
    bucket = env_value("S3_REPORT_BUCKET")
    if upload_s3_enabled:
        if not bucket:
            s3_artifacts = {
                "ok": False,
                "enabled": True,
                "error_type": "ConfigurationError",
                "error": "S3_REPORT_BUCKET is empty.",
            }
        elif markdown_write.get("ok"):
            s3_artifacts = {
                "ok": True,
                "enabled": True,
                "bucket": bucket,
                **build_s3_locations(
                    bucket,
                    env_value("S3_REPORT_PREFIX", "reports"),
                    environment,
                    source_skill,
                    artifact_basename,
                    payload,
                    generated_at,
                ),
            }
            markdown_upload = put_s3_object(
                region,
                bucket,
                s3_artifacts["markdown_key"],
                markdown.encode("utf-8"),
                "text/markdown; charset=utf-8",
            )
            s3_artifacts["markdown_upload"] = markdown_upload
            if not markdown_upload.get("ok"):
                s3_artifacts["ok"] = False
        else:
            s3_artifacts = {
                "ok": False,
                "enabled": True,
                "error_type": "DependencyError",
                "error": "Markdown was not written locally, so S3 upload was skipped.",
            }

    summary: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "task_type": task_type,
        "job_id": job_id,
        "selected_skill": selected_skill,
        "status": "failed" if errors else "success",
        "overall_ok": not errors,
        "timestamp_utc": generated_at,
        "aws_region": region,
        "aws_account_id": account_id or None,
        "environment": environment,
        "report_id": report_id,
        "artifact_basename": artifact_basename,
        "source": source,
        "source_task_type": source_task_type,
        "normalized_source_task_type": normalized_source_task,
        "source_skill": source_skill,
        "source_timestamp_utc": payload.get("timestamp_utc"),
        "source_overall_ok": payload.get("overall_ok"),
        "report_status": report_status,
        "summary_mode": presentation.get("summary_mode"),
        "model_used": presentation.get("model_used"),
        "provider": presentation.get("provider"),
        "llm_error": presentation.get("llm_error"),
        "executive_summary": presentation.get("executive_summary"),
        "risk_explanation": presentation.get("risk_explanation"),
        "warning_count": len(warnings),
        "failure_count": len(failures),
        "cost_risk_count": len(cost_risks),
        "recommendation_count": len(recommendations),
        "markdown_sha256": markdown_sha256,
        "warnings": warnings,
        "failures": failures,
        "recommendations": recommendations,
        "errors": errors,
        "checks": {"sts_get_caller_identity": sts_check},
        "history_aggregation": input_result.get("history", {"enabled": False}),
        "artifacts": {
            "local": {
                "markdown": markdown_write,
                "summary": {"ok": False, "path": str(summary_path), "pending": True},
            },
            "s3": s3_artifacts,
            "dynamodb_report_index": {"ok": True, "enabled": False},
        },
    }

    if upload_s3_enabled and not s3_artifacts.get("ok"):
        summary["errors"].append(
            {
                "code": "s3_report_upload_failed",
                "message": s3_artifacts.get("error") or s3_artifacts.get("markdown_upload", {}).get("error"),
                "error_type": s3_artifacts.get("error_type") or s3_artifacts.get("markdown_upload", {}).get("error_type"),
            }
        )

    summary["status"] = "success" if not summary["errors"] else (
        "partial_success" if markdown_write.get("ok") else "failed"
    )
    summary["overall_ok"] = not summary["errors"]

    summary_write = write_summary(summary_path, summary)
    summary["artifacts"]["local"]["summary"] = summary_write
    if not summary_write.get("ok"):
        summary["errors"].append(
            {
                "code": "local_summary_write_failed",
                "message": summary_write.get("error"),
                "error_type": summary_write.get("error_type"),
            }
        )

    if (
        upload_s3_enabled
        and summary["artifacts"]["s3"].get("enabled")
        and summary["artifacts"]["s3"].get("ok")
        and summary["artifacts"]["s3"].get("summary_key")
        and summary_write.get("ok")
    ):
        summary_upload = put_s3_object(
            region,
            bucket,
            summary["artifacts"]["s3"]["summary_key"],
            json.dumps(jsonable(sanitize(summary)), ensure_ascii=False, indent=2).encode("utf-8"),
            "application/json",
        )
        summary["artifacts"]["s3"]["summary_upload"] = summary_upload
        if not summary_upload.get("ok"):
            summary["artifacts"]["s3"]["ok"] = False
            summary["errors"].append(
                {
                    "code": "s3_summary_upload_failed",
                    "message": summary_upload.get("error"),
                    "error_type": summary_upload.get("error_type"),
                }
            )

    if write_index_enabled and not summary["errors"]:
        index_result = write_report_index(region, env_value("DYNAMODB_REPORTS_TABLE"), summary)
        summary["artifacts"]["dynamodb_report_index"] = index_result
        if not index_result.get("ok"):
            summary["errors"].append(
                {
                    "code": "report_index_write_failed",
                    "message": index_result.get("error"),
                    "error_type": index_result.get("error_type"),
                    "aws_error_code": index_result.get("aws_error_code"),
                }
            )

    summary["status"] = "success" if not summary["errors"] else (
        "partial_success" if markdown_write.get("ok") else "failed"
    )
    summary["overall_ok"] = not summary["errors"]

    # Rewrite the S3 JSON once after the optional DynamoDB index is known.
    if (
        upload_s3_enabled
        and summary["artifacts"]["s3"].get("enabled")
        and summary["artifacts"]["s3"].get("ok")
        and summary["artifacts"]["s3"].get("summary_key")
        and summary_write.get("ok")
    ):
        final_summary_upload = put_s3_object(
            region,
            bucket,
            summary["artifacts"]["s3"]["summary_key"],
            json.dumps(jsonable(sanitize(summary)), ensure_ascii=False, indent=2).encode("utf-8"),
            "application/json",
        )
        summary["artifacts"]["s3"]["final_summary_upload"] = final_summary_upload
        if not final_summary_upload.get("ok"):
            summary["artifacts"]["s3"]["ok"] = False
            summary["errors"].append(
                {
                    "code": "final_s3_summary_upload_failed",
                    "message": final_summary_upload.get("error"),
                    "error_type": final_summary_upload.get("error_type"),
                }
            )

    summary["status"] = "success" if not summary["errors"] else (
        "partial_success" if markdown_write.get("ok") else "failed"
    )
    summary["overall_ok"] = not summary["errors"]

    summary["artifacts"]["local"]["summary"] = {"ok": True, "path": str(summary_path)}
    final_local_write = write_summary(summary_path, summary)
    if not final_local_write.get("ok"):
        summary["artifacts"]["local"]["summary"] = final_local_write
        summary["errors"].append(
            {
                "code": "final_local_summary_write_failed",
                "message": final_local_write.get("error"),
                "error_type": final_local_write.get("error_type"),
            }
        )
        summary["status"] = "partial_success" if markdown_write.get("ok") else "failed"
        summary["overall_ok"] = False

    print(json.dumps(jsonable(sanitize(summary)), ensure_ascii=False, indent=2))
    return 0 if summary["overall_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
