#!/usr/bin/env python3
import json
import os
import sys
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
except Exception as exc:
    print(json.dumps({
        "task_type": "cost_inspection",
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


def error_result(exc: Exception) -> Dict[str, Any]:
    result: Dict[str, Any] = {
        "ok": False,
        "error": str(exc),
        "error_type": exc.__class__.__name__
    }

    if isinstance(exc, ClientError):
        err = exc.response.get("Error", {})
        result["aws_error_code"] = err.get("Code")
        result["aws_error_message"] = err.get("Message")

    return result


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


def check_cost_explorer(account_id: str) -> Dict[str, Any]:
    today = date.today()
    month_start = today.replace(day=1)
    seven_days_ago = today - timedelta(days=7)

    # Cost Explorer commonly uses us-east-1/global-style endpoint behavior.
    # Keep this separate from workload region.
    try:
        ce = boto3.client("ce", region_name="us-east-1")

        month_response = ce.get_cost_and_usage(
            TimePeriod={
                "Start": month_start.isoformat(),
                "End": today.isoformat()
            },
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
            GroupBy=[
                {
                    "Type": "DIMENSION",
                    "Key": "SERVICE"
                }
            ]
        )

        seven_day_response = ce.get_cost_and_usage(
            TimePeriod={
                "Start": seven_days_ago.isoformat(),
                "End": today.isoformat()
            },
            Granularity="DAILY",
            Metrics=["UnblendedCost"]
        )

        services = []
        for item in month_response.get("ResultsByTime", []):
            for group in item.get("Groups", []):
                keys = group.get("Keys", [])
                service_name = keys[0] if keys else "UNKNOWN"
                amount = group.get("Metrics", {}).get("UnblendedCost", {}).get("Amount")
                unit = group.get("Metrics", {}).get("UnblendedCost", {}).get("Unit")
                try:
                    numeric_amount = float(amount or 0)
                except ValueError:
                    numeric_amount = 0.0

                if numeric_amount > 0:
                    services.append({
                        "service": service_name,
                        "amount": round(numeric_amount, 6),
                        "unit": unit
                    })

        services.sort(key=lambda x: x["amount"], reverse=True)

        daily_costs = []
        total_7d = 0.0

        for item in seven_day_response.get("ResultsByTime", []):
            amount = item.get("Total", {}).get("UnblendedCost", {}).get("Amount", "0")
            unit = item.get("Total", {}).get("UnblendedCost", {}).get("Unit", "USD")
            try:
                numeric_amount = float(amount)
            except ValueError:
                numeric_amount = 0.0

            total_7d += numeric_amount
            daily_costs.append({
                "start": item.get("TimePeriod", {}).get("Start"),
                "end": item.get("TimePeriod", {}).get("End"),
                "amount": round(numeric_amount, 6),
                "unit": unit
            })

        return {
            "ok": True,
            "account_id": account_id,
            "month_start": month_start.isoformat(),
            "today": today.isoformat(),
            "top_services_current_month": services[:10],
            "daily_costs_last_7_days": daily_costs,
            "total_unblended_cost_last_7_days_usd": round(total_7d, 6)
        }

    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result["note"] = "Cost Explorer may require billing permissions and may not be available for every account setup."
        return result


def check_budgets(account_id: str) -> Dict[str, Any]:
    if not account_id:
        return {
            "ok": False,
            "error": "account_id_missing"
        }

    try:
        budgets = boto3.client("budgets", region_name="us-east-1")
        response = budgets.describe_budgets(AccountId=account_id, MaxResults=20)
        budget_items = response.get("Budgets", [])

        summarized = []
        for item in budget_items:
            summarized.append({
                "budget_name": item.get("BudgetName"),
                "budget_type": item.get("BudgetType"),
                "time_unit": item.get("TimeUnit"),
                "budget_limit": item.get("BudgetLimit"),
                "calculated_spend": item.get("CalculatedSpend")
            })

        return {
            "ok": True,
            "budget_count_in_first_response": len(budget_items),
            "sample_budgets": summarized[:10]
        }

    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result["note"] = "Budgets API requires billing/budgets read permissions."
        return result


def check_cloudwatch_log_cost_risk(region: str) -> Dict[str, Any]:
    try:
        logs = boto3.client("logs", region_name=region)
        paginator = logs.get_paginator("describe_log_groups")

        total_groups = 0
        total_stored_bytes = 0
        missing_retention = []
        largest_groups = []

        for page in paginator.paginate(PaginationConfig={"MaxItems": 100}):
            for group in page.get("logGroups", []):
                total_groups += 1
                stored_bytes = int(group.get("storedBytes", 0) or 0)
                total_stored_bytes += stored_bytes

                if "retentionInDays" not in group:
                    missing_retention.append(group.get("logGroupName"))

                largest_groups.append({
                    "log_group_name": group.get("logGroupName"),
                    "stored_bytes": stored_bytes,
                    "retention_in_days": group.get("retentionInDays")
                })

        largest_groups.sort(key=lambda x: x["stored_bytes"], reverse=True)

        return {
            "ok": True,
            "checked_log_groups": total_groups,
            "total_stored_bytes_in_checked_groups": total_stored_bytes,
            "total_stored_mb_in_checked_groups": round(total_stored_bytes / 1024 / 1024, 3),
            "missing_retention_count": len(missing_retention),
            "missing_retention_sample": missing_retention[:20],
            "largest_log_groups_sample": largest_groups[:10]
        }

    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return error_result(exc)


def check_nat_gateways(region: str) -> Dict[str, Any]:
    try:
        ec2 = boto3.client("ec2", region_name=region)
        response = ec2.describe_nat_gateways()

        nat_gateways = []
        for ngw in response.get("NatGateways", []):
            nat_gateways.append({
                "nat_gateway_id": ngw.get("NatGatewayId"),
                "state": ngw.get("State"),
                "vpc_id": ngw.get("VpcId"),
                "subnet_id": ngw.get("SubnetId"),
                "created_time": ngw.get("CreateTime").isoformat() if ngw.get("CreateTime") else None
            })

        active_like = [
            item for item in nat_gateways
            if item.get("state") in ("pending", "available")
        ]

        return {
            "ok": True,
            "nat_gateway_count": len(nat_gateways),
            "active_or_pending_count": len(active_like),
            "nat_gateways": nat_gateways[:20],
            "cost_risk": len(active_like) > 0
        }

    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return error_result(exc)


def check_efs_file_systems(region: str) -> Dict[str, Any]:
    try:
        efs = boto3.client("efs", region_name=region)
        response = efs.describe_file_systems()

        file_systems = []
        total_size_bytes = 0

        for fs in response.get("FileSystems", []):
            size_bytes = int(fs.get("SizeInBytes", {}).get("Value", 0) or 0)
            total_size_bytes += size_bytes

            file_systems.append({
                "file_system_id": fs.get("FileSystemId"),
                "name": fs.get("Name"),
                "life_cycle_state": fs.get("LifeCycleState"),
                "performance_mode": fs.get("PerformanceMode"),
                "throughput_mode": fs.get("ThroughputMode"),
                "encrypted": fs.get("Encrypted"),
                "size_bytes": size_bytes,
                "size_mb": round(size_bytes / 1024 / 1024, 3)
            })

        return {
            "ok": True,
            "file_system_count": len(file_systems),
            "total_size_bytes": total_size_bytes,
            "total_size_mb": round(total_size_bytes / 1024 / 1024, 3),
            "file_systems": file_systems[:20],
            "cost_risk": len(file_systems) > 0
        }

    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        return error_result(exc)


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

        billing_mode = table.get("BillingModeSummary", {}).get("BillingMode", "PROVISIONED")

        provisioned = table.get("ProvisionedThroughput", {})

        return {
            "ok": True,
            "configured": True,
            "table_name": table.get("TableName"),
            "table_status": table.get("TableStatus"),
            "billing_mode": billing_mode,
            "item_count": table.get("ItemCount"),
            "table_size_bytes": table.get("TableSizeBytes"),
            "provisioned_read_capacity_units": provisioned.get("ReadCapacityUnits"),
            "provisioned_write_capacity_units": provisioned.get("WriteCapacityUnits"),
            "cost_risk": billing_mode == "PROVISIONED"
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
        visible = int(attributes.get("ApproximateNumberOfMessages", "0"))
        not_visible = int(attributes.get("ApproximateNumberOfMessagesNotVisible", "0"))
        delayed = int(attributes.get("ApproximateNumberOfMessagesDelayed", "0"))

        return {
            "ok": True,
            "configured": True,
            "queue_url_set": True,
            "approximate_number_of_messages": visible,
            "approximate_number_of_messages_not_visible": not_visible,
            "approximate_number_of_messages_delayed": delayed,
            "cost_or_operational_risk": visible > 0 or not_visible > 0 or delayed > 0
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
        attrs = response.get("Attributes", {})

        pending = int(attrs.get("SubscriptionsPending", "0"))
        confirmed = int(attrs.get("SubscriptionsConfirmed", "0"))

        return {
            "ok": True,
            "configured": True,
            "topic_arn": topic_arn,
            "subscriptions_confirmed": confirmed,
            "subscriptions_pending": pending,
            "cost_or_delivery_risk": pending > 0 or confirmed == 0
        }

    except (NoCredentialsError, BotoCoreError, ClientError, Exception) as exc:
        result = error_result(exc)
        result.update({
            "configured": True,
            "topic_arn": topic_arn
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

        if aws_code in (
            "AccessDenied",
            "AccessDeniedException",
            "UnauthorizedOperation",
            "AccessDeniedException"
        ) or "AccessDenied" in error_text or "not authorized" in error_text:
            limitations.append({
                "check": name,
                "aws_error_code": aws_code or None,
                "message": check.get("aws_error_message") or error_text
            })

    return limitations


def build_cost_risks(checks: Dict[str, Dict[str, Any]]) -> List[Dict[str, Any]]:
    risks: List[Dict[str, Any]] = []

    nat = checks.get("nat_gateways", {})
    if nat.get("ok") and nat.get("active_or_pending_count", 0) > 0:
        risks.append({
            "risk": "nat_gateway_active",
            "severity": "high",
            "detail": f"{nat.get('active_or_pending_count')} NAT Gateway(s) are active or pending.",
            "recommendation": "Confirm NAT Gateway is intentionally required. Avoid it in this low-cost MVP unless necessary."
        })

    efs = checks.get("efs_file_systems", {})
    if efs.get("ok") and efs.get("file_system_count", 0) > 0:
        risks.append({
            "risk": "efs_storage_exists",
            "severity": "medium",
            "detail": f"{efs.get('file_system_count')} EFS file system(s) detected.",
            "recommendation": "Confirm EFS is needed for the demo and destroy it after testing if not required."
        })

    logs = checks.get("cloudwatch_log_cost_risk", {})
    if logs.get("ok") and logs.get("missing_retention_count", 0) > 0:
        risks.append({
            "risk": "cloudwatch_logs_no_retention",
            "severity": "medium",
            "detail": f"{logs.get('missing_retention_count')} checked log group(s) have no retention policy.",
            "recommendation": "Set log retention days in Terraform to control long-term log storage cost."
        })

    dynamodb = checks.get("dynamodb_jobs_table", {})
    if dynamodb.get("ok") and dynamodb.get("cost_risk"):
        risks.append({
            "risk": "dynamodb_provisioned_capacity",
            "severity": "low",
            "detail": "DynamoDB table appears to use PROVISIONED capacity.",
            "recommendation": "For the MVP, consider PAY_PER_REQUEST unless provisioned mode is intentional."
        })

    sqs = checks.get("sqs_queue", {})
    if sqs.get("ok") and sqs.get("cost_or_operational_risk"):
        risks.append({
            "risk": "sqs_messages_pending",
            "severity": "low",
            "detail": "SQS queue has visible, delayed, or in-flight messages.",
            "recommendation": "Check whether messages are expected or stuck."
        })

    sns = checks.get("sns_topic", {})
    if sns.get("ok") and sns.get("cost_or_delivery_risk"):
        risks.append({
            "risk": "sns_subscription_not_confirmed_or_missing",
            "severity": "low",
            "detail": "SNS topic has pending subscriptions or no confirmed subscriptions.",
            "recommendation": "Confirm notification subscription before relying on alert delivery."
        })

    return risks


def build_recommendations(cost_risks: List[Dict[str, Any]], permission_limitations: List[Dict[str, Any]]) -> List[str]:
    recommendations: List[str] = []

    if permission_limitations:
        recommendations.append("Review IAM permissions for cost inspection read-only APIs that returned AccessDenied.")

    for risk in cost_risks:
        rec = risk.get("recommendation")
        if rec:
            recommendations.append(rec)

    if not recommendations:
        recommendations.append("No immediate cost action is required based on current checks.")

    return recommendations


def main() -> int:
    region = get_region()
    strict_mode = env_bool("OPENCLAW_COST_INSPECTION_STRICT", False)

    task_type = env_value("OPENCLAW_TASK_TYPE", "cost_inspection")
    job_id = env_value("OPENCLAW_JOB_ID", "unknown")
    selected_skill = env_value("OPENCLAW_SELECTED_SKILL", "aws-cost-inspection")

    result: Dict[str, Any] = {
        "task_type": task_type,
        "job_id": job_id,
        "selected_skill": selected_skill,
        "timestamp_utc": now_utc(),
        "aws_region": region,
        "strict_mode": strict_mode,
        "checks": {},
        "cost_risks": [],
        "permission_limitations": [],
        "recommendations": [],
        "overall_ok": False
    }

    checks: Dict[str, Dict[str, Any]] = {}

    checks["sts_get_caller_identity"] = check_sts(region)

    account_id = ""
    if checks["sts_get_caller_identity"].get("ok"):
        account_id = checks["sts_get_caller_identity"].get("account", "")

    checks["cost_explorer"] = check_cost_explorer(account_id)
    checks["budgets"] = check_budgets(account_id)
    checks["cloudwatch_log_cost_risk"] = check_cloudwatch_log_cost_risk(region)
    checks["nat_gateways"] = check_nat_gateways(region)
    checks["efs_file_systems"] = check_efs_file_systems(region)
    checks["ecs_cluster"] = check_ecs_cluster(region, env_value("ECS_CLUSTER_NAME"))
    checks["dynamodb_jobs_table"] = check_dynamodb_table(region, env_value("DYNAMODB_JOBS_TABLE"))
    checks["sqs_queue"] = check_sqs_queue(region, env_value("SQS_QUEUE_URL"))
    checks["sns_topic"] = check_sns_topic(region, env_value("SNS_TOPIC_ARN"))

    result["checks"] = checks
    result["permission_limitations"] = collect_permission_limitations(checks)
    result["cost_risks"] = build_cost_risks(checks)
    result["recommendations"] = build_recommendations(
        result["cost_risks"],
        result["permission_limitations"]
    )

    mandatory_checks = ["sts_get_caller_identity"]

    if strict_mode:
        mandatory_checks.extend([
            "cost_explorer",
            "budgets",
            "cloudwatch_log_cost_risk",
            "nat_gateways",
            "efs_file_systems"
        ])

    result["overall_ok"] = all(
        checks.get(name, {}).get("ok") is True
        for name in mandatory_checks
    )

    print(json.dumps(result, ensure_ascii=False, indent=2))

    return 0 if result["overall_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
