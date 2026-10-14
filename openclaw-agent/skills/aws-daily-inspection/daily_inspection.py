#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
except Exception as exc:
    print(json.dumps({
        "task_type": "daily_inspection",
        "overall_ok": False,
        "fatal_error": "boto3_import_failed",
        "detail": str(exc)
    }, ensure_ascii=False, indent=2))
    sys.exit(1)


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def get_region() -> str:
    return (
        os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
        or "ap-northeast-1"
    )


def env_value(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on", "enabled")


def safe_secret_presence(name: str) -> Dict[str, Any]:
    value = os.environ.get(name)
    return {
        "present": bool(value),
        "length": len(value) if value else 0
    }


def error_result(exc: Exception) -> Dict[str, Any]:
    result = {
        "ok": False,
        "error": str(exc),
        "error_type": exc.__class__.__name__
    }

    if isinstance(exc, ClientError):
        err = exc.response.get("Error", {})
        result["aws_error_code"] = err.get("Code")
        result["aws_error_message"] = err.get("Message")

    return result


def get_ecs_task_metadata() -> Dict[str, Any]:
    metadata_uri = os.environ.get("ECS_CONTAINER_METADATA_URI_V4") or os.environ.get("ECS_CONTAINER_METADATA_URI")

    if not metadata_uri:
        return {
            "ok": False,
            "available": False,
            "reason": "metadata_uri_not_present"
        }

    try:
        with urllib.request.urlopen(metadata_uri, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8"))

        safe_data = {
            "container_name": data.get("Name"),
            "image": data.get("Image"),
            "image_id": data.get("ImageID"),
            "docker_id": data.get("DockerId"),
            "labels": data.get("Labels", {}),
            "created_at": data.get("CreatedAt"),
            "started_at": data.get("StartedAt")
        }

        task_uri = metadata_uri.rstrip("/") + "/task"
        task_data = {}
        try:
            with urllib.request.urlopen(task_uri, timeout=2) as task_resp:
                task_raw = json.loads(task_resp.read().decode("utf-8"))
                task_data = {
                    "cluster": task_raw.get("Cluster"),
                    "task_arn": task_raw.get("TaskARN"),
                    "family": task_raw.get("Family"),
                    "revision": task_raw.get("Revision"),
                    "availability_zone": task_raw.get("AvailabilityZone"),
                    "launch_type": task_raw.get("LaunchType")
                }
        except Exception:
            task_data = {}

        return {
            "ok": True,
            "available": True,
            "container": safe_data,
            "task": task_data
        }
    except Exception as exc:
        return {
            "ok": False,
            "available": True,
            "error": str(exc),
            "error_type": exc.__class__.__name__
        }


def check_sts(region: str) -> Dict[str, Any]:
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
        return error_result(exc)


def check_cloudwatch_metrics(region: str) -> Dict[str, Any]:
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
                    "metric_name": metric.get("MetricName"),
                    "dimensions": metric.get("Dimensions", [])
                }
                for metric in metrics[:5]
            ]
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return error_result(exc)


def check_cloudwatch_alarms(region: str) -> Dict[str, Any]:
    try:
        cloudwatch = boto3.client("cloudwatch", region_name=region)
        response = cloudwatch.describe_alarms(MaxRecords=20)
        alarms = response.get("MetricAlarms", [])

        state_counts: Dict[str, int] = {}
        summarized_alarms: List[Dict[str, Any]] = []

        for alarm in alarms:
            state = alarm.get("StateValue", "UNKNOWN")
            state_counts[state] = state_counts.get(state, 0) + 1

            summarized_alarms.append({
                "alarm_name": alarm.get("AlarmName"),
                "state": alarm.get("StateValue"),
                "metric_name": alarm.get("MetricName"),
                "namespace": alarm.get("Namespace"),
                "updated_at": alarm.get("StateUpdatedTimestamp").isoformat() if alarm.get("StateUpdatedTimestamp") else None
            })

        return {
            "ok": True,
            "alarm_count_in_first_response": len(alarms),
            "state_counts": state_counts,
            "sample_alarms": summarized_alarms[:10]
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return error_result(exc)


def check_log_groups(region: str) -> Dict[str, Any]:
    try:
        logs = boto3.client("logs", region_name=region)
        response = logs.describe_log_groups(limit=20)
        groups = response.get("logGroups", [])

        missing_retention = [
            group.get("logGroupName")
            for group in groups
            if "retentionInDays" not in group
        ]

        return {
            "ok": True,
            "log_group_count_in_first_response": len(groups),
            "missing_retention_count_in_first_response": len(missing_retention),
            "missing_retention_sample": missing_retention[:10],
            "sample_log_groups": [
                {
                    "log_group_name": group.get("logGroupName"),
                    "retention_in_days": group.get("retentionInDays"),
                    "stored_bytes": group.get("storedBytes")
                }
                for group in groups[:10]
            ]
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return error_result(exc)


def check_s3_bucket(region: str, bucket_name: str) -> Dict[str, Any]:
    if not bucket_name:
        return {
            "ok": True,
            "configured": False,
            "reason": "S3_REPORT_BUCKET not set"
        }

    try:
        s3 = boto3.client("s3", region_name=region)
        s3.head_bucket(Bucket=bucket_name)
        return {
            "ok": True,
            "configured": True,
            "bucket": bucket_name,
            "accessible": True
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "bucket": bucket_name,
            "accessible": False
        })
        return result


def check_dynamodb_table(region: str, table_name: str) -> Dict[str, Any]:
    if not table_name:
        return {
            "ok": True,
            "configured": False,
            "reason": "DYNAMODB_JOBS_TABLE not set"
        }

    try:
        dynamodb = boto3.client("dynamodb", region_name=region)
        response = dynamodb.describe_table(TableName=table_name)
        table = response.get("Table", {})
        return {
            "ok": True,
            "configured": True,
            "table_name": table.get("TableName"),
            "table_status": table.get("TableStatus"),
            "billing_mode": table.get("BillingModeSummary", {}).get("BillingMode"),
            "item_count": table.get("ItemCount"),
            "table_size_bytes": table.get("TableSizeBytes")
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "table_name": table_name
        })
        return result


def check_sqs_queue(region: str, queue_url: str) -> Dict[str, Any]:
    if not queue_url:
        return {
            "ok": True,
            "configured": False,
            "reason": "SQS_QUEUE_URL not set"
        }

    try:
        sqs = boto3.client("sqs", region_name=region)
        response = sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=[
                "ApproximateNumberOfMessages",
                "ApproximateNumberOfMessagesNotVisible",
                "ApproximateNumberOfMessagesDelayed",
                "CreatedTimestamp",
                "LastModifiedTimestamp"
            ]
        )
        attributes = response.get("Attributes", {})
        return {
            "ok": True,
            "configured": True,
            "queue_url_set": True,
            "attributes": attributes
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "queue_url_set": True
        })
        return result


def check_sns_topic(region: str, topic_arn: str) -> Dict[str, Any]:
    if not topic_arn:
        return {
            "ok": True,
            "configured": False,
            "reason": "SNS_TOPIC_ARN not set"
        }

    try:
        sns = boto3.client("sns", region_name=region)
        response = sns.get_topic_attributes(TopicArn=topic_arn)
        attributes = response.get("Attributes", {})
        return {
            "ok": True,
            "configured": True,
            "topic_arn": topic_arn,
            "display_name": attributes.get("DisplayName"),
            "subscriptions_confirmed": attributes.get("SubscriptionsConfirmed"),
            "subscriptions_pending": attributes.get("SubscriptionsPending")
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "topic_arn": topic_arn
        })
        return result


def check_efs(region: str, file_system_id: str) -> Dict[str, Any]:
    if not file_system_id:
        return {
            "ok": True,
            "configured": False,
            "reason": "EFS_FILE_SYSTEM_ID not set"
        }

    try:
        efs = boto3.client("efs", region_name=region)
        response = efs.describe_file_systems(FileSystemId=file_system_id)
        file_systems = response.get("FileSystems", [])
        if not file_systems:
            return {
                "ok": False,
                "configured": True,
                "file_system_id": file_system_id,
                "error": "file_system_not_found"
            }

        fs = file_systems[0]
        return {
            "ok": True,
            "configured": True,
            "file_system_id": fs.get("FileSystemId"),
            "life_cycle_state": fs.get("LifeCycleState"),
            "performance_mode": fs.get("PerformanceMode"),
            "throughput_mode": fs.get("ThroughputMode"),
            "size_bytes": fs.get("SizeInBytes", {}).get("Value")
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "file_system_id": file_system_id
        })
        return result


def check_ecs_cluster(region: str, cluster_name: str) -> Dict[str, Any]:
    if not cluster_name:
        return {
            "ok": True,
            "configured": False,
            "reason": "ECS_CLUSTER_NAME not set"
        }

    try:
        ecs = boto3.client("ecs", region_name=region)
        response = ecs.describe_clusters(clusters=[cluster_name])
        clusters = response.get("clusters", [])
        failures = response.get("failures", [])

        if not clusters:
            return {
                "ok": False,
                "configured": True,
                "cluster_name": cluster_name,
                "failures": failures,
                "error": "cluster_not_found"
            }

        cluster = clusters[0]
        return {
            "ok": True,
            "configured": True,
            "cluster_name": cluster.get("clusterName"),
            "status": cluster.get("status"),
            "running_tasks_count": cluster.get("runningTasksCount"),
            "pending_tasks_count": cluster.get("pendingTasksCount"),
            "active_services_count": cluster.get("activeServicesCount")
        }
    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "cluster_name": cluster_name
        })
        return result


def collect_permission_limitations(checks: Dict[str, Dict[str, Any]]) -> List[Dict[str, Any]]:
    limitations = []

    for name, check in checks.items():
        if not isinstance(check, dict):
            continue

        if check.get("ok") is True:
            continue

        aws_code = check.get("aws_error_code", "")
        error_text = check.get("error", "")

        if aws_code in ("AccessDenied", "AccessDeniedException", "UnauthorizedOperation") or "AccessDenied" in error_text:
            limitations.append({
                "check": name,
                "aws_error_code": aws_code or None,
                "message": check.get("aws_error_message") or error_text
            })

    return limitations


def build_warnings(checks: Dict[str, Dict[str, Any]]) -> List[str]:
    warnings = []

    alarms = checks.get("cloudwatch_alarms", {})
    if alarms.get("ok") and alarms.get("state_counts", {}).get("ALARM", 0) > 0:
        warnings.append(f"CloudWatch has {alarms['state_counts']['ALARM']} alarm(s) currently in ALARM state.")

    log_groups = checks.get("cloudwatch_log_groups", {})
    if log_groups.get("ok") and log_groups.get("missing_retention_count_in_first_response", 0) > 0:
        warnings.append("Some CloudWatch log groups in the first response do not have retention configured.")

    sqs = checks.get("sqs_queue", {})
    if sqs.get("ok") and sqs.get("configured"):
        attributes = sqs.get("attributes", {})
        visible = int(attributes.get("ApproximateNumberOfMessages", "0"))
        not_visible = int(attributes.get("ApproximateNumberOfMessagesNotVisible", "0"))
        if visible > 0 or not_visible > 0:
            warnings.append(f"SQS queue has visible={visible}, in_flight={not_visible} messages.")

    if not os.environ.get("DEEPSEEK_API_KEY"):
        warnings.append("DEEPSEEK_API_KEY is not present. LLM-backed OpenClaw tasks may fail.")

    return warnings


def build_recommendations(checks: Dict[str, Dict[str, Any]], permission_limitations: List[Dict[str, Any]]) -> List[str]:
    recommendations = []

    if permission_limitations:
        recommendations.append("Review IAM permissions for failed read-only checks that returned AccessDenied.")

    log_groups = checks.get("cloudwatch_log_groups", {})
    if log_groups.get("ok") and log_groups.get("missing_retention_count_in_first_response", 0) > 0:
        recommendations.append("Configure retention for CloudWatch log groups to reduce long-term log cost risk.")

    alarms = checks.get("cloudwatch_alarms", {})
    if alarms.get("ok") and alarms.get("state_counts", {}).get("ALARM", 0) > 0:
        recommendations.append("Inspect CloudWatch alarms currently in ALARM state before the next deployment step.")

    if not recommendations:
        recommendations.append("No immediate daily-inspection action is required based on the current read-only checks.")

    return recommendations


def main() -> int:
    region = get_region()
    strict_mode = env_bool("OPENCLAW_DAILY_INSPECTION_STRICT", False)

    task_type = env_value("OPENCLAW_TASK_TYPE", "daily_inspection")
    job_id = env_value("OPENCLAW_JOB_ID", "unknown")
    selected_skill = env_value("OPENCLAW_SELECTED_SKILL", "aws-daily-inspection")

    result: Dict[str, Any] = {
        "task_type": task_type,
        "job_id": job_id,
        "selected_skill": selected_skill,
        "timestamp_utc": now_utc(),
        "aws_region": region,
        "strict_mode": strict_mode,
        "environment": {
            "openclaw_home": env_value("OPENCLAW_HOME", "/home/node/.openclaw"),
            "openclaw_config_path": env_value("OPENCLAW_CONFIG_PATH", "/home/node/.openclaw/openclaw.json"),
            "runtime_dir": env_value("OPENCLAW_RUNTIME_DIR", "/app/runtime"),
            "workspace": env_value("OPENCLAW_WORKSPACE", "/app/runtime/workspace"),
            "prompt_path": env_value("OPENCLAW_PROMPT_PATH", ""),
            "deepseek_api_key": safe_secret_presence("DEEPSEEK_API_KEY")
        },
        "checks": {},
        "permission_limitations": [],
        "warnings": [],
        "recommendations": [],
        "overall_ok": False
    }

    checks: Dict[str, Dict[str, Any]] = {}

    checks["ecs_task_metadata"] = get_ecs_task_metadata()
    checks["sts_get_caller_identity"] = check_sts(region)
    checks["cloudwatch_metrics"] = check_cloudwatch_metrics(region)
    checks["cloudwatch_alarms"] = check_cloudwatch_alarms(region)
    checks["cloudwatch_log_groups"] = check_log_groups(region)

    checks["s3_report_bucket"] = check_s3_bucket(region, env_value("S3_REPORT_BUCKET"))
    checks["dynamodb_jobs_table"] = check_dynamodb_table(region, env_value("DYNAMODB_JOBS_TABLE"))
    checks["sqs_queue"] = check_sqs_queue(region, env_value("SQS_QUEUE_URL"))
    checks["sns_topic"] = check_sns_topic(region, env_value("SNS_TOPIC_ARN"))
    checks["efs_file_system"] = check_efs(region, env_value("EFS_FILE_SYSTEM_ID"))
    checks["ecs_cluster"] = check_ecs_cluster(region, env_value("ECS_CLUSTER_NAME"))

    result["checks"] = checks
    result["permission_limitations"] = collect_permission_limitations(checks)
    result["warnings"] = build_warnings(checks)
    result["recommendations"] = build_recommendations(checks, result["permission_limitations"])

    # In non-strict mode, only STS identity is mandatory for daily inspection.
    # Other read-only checks may fail due to missing optional resources or unfinished IAM wiring.
    mandatory_checks = ["sts_get_caller_identity"]

    if strict_mode:
        mandatory_checks.extend([
            "cloudwatch_metrics",
            "cloudwatch_alarms",
            "cloudwatch_log_groups"
        ])

    result["overall_ok"] = all(
        checks.get(name, {}).get("ok") is True
        for name in mandatory_checks
    )

    print(json.dumps(result, ensure_ascii=False, indent=2))

    return 0 if result["overall_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
