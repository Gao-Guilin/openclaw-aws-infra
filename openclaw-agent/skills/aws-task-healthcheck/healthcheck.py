#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
except Exception as exc:
    print(json.dumps({
        "task_type": "healthcheck",
        "overall_ok": False,
        "fatal_error": "boto3_import_failed",
        "detail": str(exc)
    }, ensure_ascii=False, indent=2))
    sys.exit(1)


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on", "enabled")


def safe_presence(name: str) -> dict:
    value = os.environ.get(name)
    return {
        "present": bool(value),
        "length": len(value) if value else 0
    }


def get_region() -> str:
    env_region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if env_region:
        return env_region

    # EC2 metadata fallback. Fargate usually provides region through environment variables,
    # so this is only a defensive fallback.
    try:
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        )
        with urllib.request.urlopen(token_req, timeout=2) as resp:
            token = resp.read().decode("utf-8")

        doc_req = urllib.request.Request(
            "http://169.254.169.254/latest/dynamic/instance-identity/document",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(doc_req, timeout=2) as resp:
            document = json.loads(resp.read().decode("utf-8"))

        return document.get("region") or "us-east-1"
    except Exception:
        return "us-east-1"


def check_file_json(path: str) -> dict:
    target = Path(path)
    if not target.exists():
        return {
            "ok": False,
            "path": path,
            "error": "file_not_found"
        }

    try:
        with target.open("r", encoding="utf-8") as fh:
            json.load(fh)
        return {
            "ok": True,
            "path": path,
            "size_bytes": target.stat().st_size
        }
    except Exception as exc:
        return {
            "ok": False,
            "path": path,
            "error": "invalid_json_or_unreadable",
            "detail": str(exc)
        }


def check_directory(path: str) -> dict:
    target = Path(path)
    if not target.exists():
        return {
            "ok": False,
            "path": path,
            "error": "directory_not_found"
        }
    if not target.is_dir():
        return {
            "ok": False,
            "path": path,
            "error": "not_a_directory"
        }
    return {
        "ok": True,
        "path": path
    }


def check_openclaw_cli() -> dict:
    exe = shutil.which("openclaw")
    if not exe:
        return {
            "ok": False,
            "error": "openclaw_not_found_in_path"
        }

    try:
        proc = subprocess.run(
            ["openclaw", "--version"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10
        )
        return {
            "ok": proc.returncode == 0,
            "path": exe,
            "returncode": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip()
        }
    except Exception as exc:
        return {
            "ok": False,
            "path": exe,
            "error": str(exc)
        }


def check_sts(region: str) -> dict:
    try:
        sts = boto3.client("sts", region_name=region)
        identity = sts.get_caller_identity()
        return {
            "ok": True,
            "account": identity.get("Account"),
            "arn": identity.get("Arn"),
            "user_id": identity.get("UserId")
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return {
            "ok": False,
            "error": str(exc)
        }


def check_cloudwatch(region: str) -> dict:
    try:
        cloudwatch = boto3.client("cloudwatch", region_name=region)
        response = cloudwatch.list_metrics(Namespace="AWS/EC2")
        metrics = response.get("Metrics", [])
        return {
            "ok": True,
            "namespace": "AWS/EC2",
            "metric_count_in_first_response": len(metrics),
            "sample_metrics": [
                {
                    "metric_name": item.get("MetricName"),
                    "dimensions": item.get("Dimensions", [])
                }
                for item in metrics[:5]
            ]
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return {
            "ok": False,
            "error": str(exc)
        }


def main() -> int:
    region = get_region()
    require_aws = env_bool("OPENCLAW_REQUIRE_AWS", True)

    task_type = os.environ.get("OPENCLAW_TASK_TYPE", "healthcheck")
    job_id = os.environ.get("OPENCLAW_JOB_ID", "unknown")
    selected_skill = os.environ.get("OPENCLAW_SELECTED_SKILL", "aws-task-healthcheck")

    openclaw_home = os.environ.get("OPENCLAW_HOME", "/home/node/.openclaw")
    openclaw_config_path = os.environ.get("OPENCLAW_CONFIG_PATH", "/home/node/.openclaw/openclaw.json")
    runtime_dir = os.environ.get("OPENCLAW_RUNTIME_DIR", "/app/runtime")
    workspace = os.environ.get("OPENCLAW_WORKSPACE", f"{runtime_dir}/workspace")
    prompt_path = os.environ.get("OPENCLAW_PROMPT_PATH", "")

    result = {
        "task_type": task_type,
        "job_id": job_id,
        "selected_skill": selected_skill,
        "timestamp_utc": now_utc(),
        "aws_region": region,
        "require_aws": require_aws,
        "checks": {},
        "warnings": [],
        "overall_ok": False
    }

    result["checks"]["environment"] = {
        "ok": True,
        "openclaw_home": openclaw_home,
        "openclaw_config_path": openclaw_config_path,
        "runtime_dir": runtime_dir,
        "workspace": workspace,
        "prompt_path": prompt_path,
        "deepseek_api_key": safe_presence("DEEPSEEK_API_KEY"),
        "ecs_credentials_relative_uri_present": bool(os.environ.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")),
        "ecs_credentials_full_uri_present": bool(os.environ.get("AWS_CONTAINER_CREDENTIALS_FULL_URI"))
    }

    if not os.environ.get("DEEPSEEK_API_KEY"):
        result["warnings"].append("DEEPSEEK_API_KEY is not present. LLM-backed OpenClaw tasks may fail.")

    result["checks"]["openclaw_home"] = check_directory(openclaw_home)
    result["checks"]["runtime_dir"] = check_directory(runtime_dir)
    result["checks"]["workspace"] = check_directory(workspace)
    result["checks"]["openclaw_config_json"] = check_file_json(openclaw_config_path)
    result["checks"]["openclaw_cli"] = check_openclaw_cli()

    if prompt_path:
        result["checks"]["prompt_file"] = {
            "ok": Path(prompt_path).exists(),
            "path": prompt_path
        }
    else:
        result["checks"]["prompt_file"] = {
            "ok": False,
            "error": "OPENCLAW_PROMPT_PATH is empty"
        }

    result["checks"]["sts_get_caller_identity"] = check_sts(region)
    result["checks"]["cloudwatch_list_metrics"] = check_cloudwatch(region)

    mandatory_checks = [
        "openclaw_home",
        "runtime_dir",
        "workspace",
        "openclaw_config_json",
        "openclaw_cli",
        "prompt_file"
    ]

    if require_aws:
        mandatory_checks.extend([
            "sts_get_caller_identity",
            "cloudwatch_list_metrics"
        ])
    else:
        if not result["checks"]["sts_get_caller_identity"]["ok"]:
            result["warnings"].append("AWS STS check failed, but OPENCLAW_REQUIRE_AWS=false.")
        if not result["checks"]["cloudwatch_list_metrics"]["ok"]:
            result["warnings"].append("CloudWatch check failed, but OPENCLAW_REQUIRE_AWS=false.")

    result["overall_ok"] = all(
        result["checks"].get(name, {}).get("ok") is True
        for name in mandatory_checks
    )

    print(json.dumps(result, ensure_ascii=False, indent=2))

    return 0 if result["overall_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
