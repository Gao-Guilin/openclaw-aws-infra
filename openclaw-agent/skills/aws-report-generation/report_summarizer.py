#!/usr/bin/env python3
"""LLM-backed Chinese summary helper for aws-report-generation.

The report generator remains the authority for facts and report structure.
This module only asks OpenClaw/DeepSeek for three bounded presentation fields:
- executive_summary
- risk_explanation
- recommended_actions

If the model call or validation fails, the caller is expected to fall back to
deterministic template rendering.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping


ALLOWED_MODELS = {
    "flash": "deepseek/deepseek-v4-flash",
    "pro": "deepseek/deepseek-v4-pro",
}


def _compact_json(value: Any, max_chars: int = 120_000) -> str:
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2)
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "\n...TRUNCATED..."


def build_model_payload(payload: Mapping[str, Any], source_task_type: str) -> Dict[str, Any]:
    """Return a bounded allowlisted view of the source result for the model."""
    common = {
        "task_type": payload.get("task_type") or source_task_type,
        "job_id": payload.get("job_id"),
        "timestamp_utc": payload.get("timestamp_utc"),
        "aws_region": payload.get("aws_region"),
        "overall_ok": payload.get("overall_ok"),
        "status": payload.get("status"),
        "checks": payload.get("checks", {}),
        "warnings": payload.get("warnings", []),
        "permission_limitations": payload.get("permission_limitations", []),
        "errors": payload.get("errors", []),
    }

    normalized = source_task_type.replace("-", "_")
    if normalized in {"healthcheck", "task_healthcheck", "aws_task_healthcheck"}:
        pass
    elif normalized in {"daily_inspection", "aws_daily_inspection"}:
        common["recommendations"] = payload.get("recommendations", [])
    elif normalized in {"cost_inspection", "aws_cost_inspection"}:
        common["cost_risks"] = payload.get("cost_risks", [])
        common["recommendations"] = payload.get("recommendations", [])
    elif normalized in {"alert_analysis", "aws_alert_analysis"}:
        common.update(
            {
                "alert_name": payload.get("alert_name"),
                "alert_state": payload.get("alert_state"),
                "event_type": payload.get("event_type"),
                "severity": payload.get("severity"),
                "human_action_required": payload.get("human_action_required"),
                "confirmed_facts": payload.get("confirmed_facts", []),
                "likely_causes": payload.get("likely_causes", []),
                "unknowns": payload.get("unknowns", []),
                "recommended_next_checks": payload.get("recommended_next_checks", []),
            }
        )
    else:
        common["recommendations"] = payload.get("recommendations", [])
        common["cost_risks"] = payload.get("cost_risks", [])

    return common


def build_prompt(
    payload: Mapping[str, Any],
    source_task_type: str,
    base_prompt_path: str | None = None,
) -> str:
    base_prompt = ""
    if base_prompt_path:
        path = Path(base_prompt_path)
        if path.is_file():
            base_prompt = path.read_text(encoding="utf-8").strip()

    model_payload = build_model_payload(payload, source_task_type)
    return f"""{base_prompt}

你现在只负责把已经确定的结构化事实解释成中文运维摘要。

强制规则：
1. 不得调用工具，不得读取其他文件，不得访问 AWS，不得执行命令。
2. 不得改变、覆盖或重新判断 overall_ok、status、severity、checks、confirmed_facts 等事实字段。
3. confirmed_facts 是事实；likely_causes 只能描述为“可能原因/假设”，不得写成已确认根因。
4. 对证据不足的内容必须明确说明未知或证据不足，不得补造事实。
5. 只输出一个合法 JSON 对象，不要 Markdown，不要代码块，不要额外文字。
6. 全部面向人的叙述使用简体中文；AWS 服务名、字段名、错误码可保留英文。
7. recommended_actions 只能给安全的人工检查/观察建议，不得自动修改基础设施。

只允许以下输出结构：
{{
  "executive_summary": "2-5 句中文总结",
  "risk_explanation": "中文风险说明；无明显风险时明确写当前未发现需要立即处理的风险",
  "recommended_actions": ["建议1", "建议2"]
}}

源任务类型：{source_task_type}
结构化事实：
{_compact_json(model_payload)}
""".strip() + "\n"


def _strip_code_fence(text: str) -> str:
    stripped = text.strip()
    match = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.DOTALL | re.IGNORECASE)
    return match.group(1).strip() if match else stripped


def parse_model_output(text: str) -> Dict[str, Any]:
    candidate = _strip_code_fence(text)
    try:
        value = json.loads(candidate)
    except json.JSONDecodeError:
        start = candidate.find("{")
        end = candidate.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("model output did not contain a JSON object")
        value = json.loads(candidate[start : end + 1])

    if not isinstance(value, Mapping):
        raise ValueError("model output must be a JSON object")

    executive_summary = value.get("executive_summary")
    risk_explanation = value.get("risk_explanation")
    recommended_actions = value.get("recommended_actions")

    if not isinstance(executive_summary, str) or not executive_summary.strip():
        raise ValueError("executive_summary must be a non-empty string")
    if not isinstance(risk_explanation, str) or not risk_explanation.strip():
        raise ValueError("risk_explanation must be a non-empty string")
    if not isinstance(recommended_actions, list):
        raise ValueError("recommended_actions must be a list")

    clean_actions = [str(item).strip() for item in recommended_actions if str(item).strip()]
    return {
        "executive_summary": executive_summary.strip(),
        "risk_explanation": risk_explanation.strip(),
        "recommended_actions": clean_actions[:8],
    }


def summarize_with_openclaw(
    payload: Mapping[str, Any],
    source_task_type: str,
    model_tier: str,
    *,
    prompt_path: str | None = None,
    config_path: str | None = None,
    workspace: str | None = None,
    timeout_seconds: int = 120,
) -> Dict[str, Any]:
    """Run one local OpenClaw turn and validate the bounded JSON reply."""
    if model_tier not in ALLOWED_MODELS:
        raise ValueError(f"unsupported model tier: {model_tier}")
    if not os.environ.get("DEEPSEEK_API_KEY"):
        raise RuntimeError("DEEPSEEK_API_KEY is not available")

    model = ALLOWED_MODELS[model_tier]
    config = config_path or os.environ.get("OPENCLAW_CONFIG_PATH", "/home/node/.openclaw/openclaw.json")
    cwd = workspace or os.environ.get("OPENCLAW_WORKSPACE", "/app/runtime/workspace")
    prompt = build_prompt(payload, source_task_type, prompt_path)

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as handle:
        handle.write(prompt)
        message_path = handle.name

    try:
        command = [
            "openclaw",
            "agent",
            "--agent",
            "main",
            "--session-key",
            f"report-{str(payload.get('job_id') or 'unknown')}",
            "--message-file",
            message_path,
            "--model",
            model,
            "--local",
            "--timeout",
            str(timeout_seconds),
        ]
        completed = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=timeout_seconds + 15,
            check=False,
            env=os.environ.copy(),
        )
        if completed.returncode != 0:
            stderr = (completed.stderr or "").strip()
            raise RuntimeError(f"OpenClaw summary failed with exit code {completed.returncode}: {stderr[:1000]}")

        parsed = parse_model_output(completed.stdout or "")
        parsed["model_used"] = model
        parsed["provider"] = "deepseek"
        return parsed
    finally:
        try:
            Path(message_path).unlink(missing_ok=True)
        except Exception:
            pass
