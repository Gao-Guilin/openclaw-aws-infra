variable "name_prefix" {
  description = "Common name prefix for ECS resources."
  type        = string
  nullable    = false
}


variable "environment" {
  description = "Deployment environment exposed to the Agent runtime."
  type        = string
  nullable    = false
}

variable "aws_region" {
  description = "AWS Region in which the ECS task runs."
  type        = string
  nullable    = false
}

variable "container_image" {
  description = "Complete ECR image URI, preferably pinned by image digest."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[^[:space:]]+(@sha256:[0-9a-f]{64}|:[^[:space:]]+)$", var.container_image))
    error_message = "container_image must be a complete image URI with either a tag or sha256 digest."
  }
}

variable "task_execution_role_arn" {
  description = "ARN of the ECS task execution role used for image pulls, logs, and secret injection."
  type        = string
  nullable    = false
}

variable "task_role_arn" {
  description = "ARN of the IAM role assumed by the running OpenClaw Agent container."
  type        = string
  nullable    = false
}

variable "cloudwatch_log_group_name" {
  description = "Name of the pre-created CloudWatch log group used by the ECS container."
  type        = string
  nullable    = false
}

variable "efs_file_system_id" {
  description = "ID of the EFS file system mounted by the task."
  type        = string
  nullable    = false
}

variable "efs_access_point_id" {
  description = "ID of the EFS access point used for the OpenClaw runtime directory."
  type        = string
  nullable    = false
}

variable "deepseek_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret containing JSON key DEEPSEEK_API_KEY."
  type        = string
  nullable    = false
}

variable "openclaw_gateway_token_secret_arn" {
  description = "ARN of the Secrets Manager secret containing JSON key OPENCLAW_GATEWAY_TOKEN."
  type        = string
  nullable    = false
}

variable "qqbot_app_id_secret_arn" {
  description = "ARN of the Secrets Manager secret containing JSON key QQBOT_APP_ID."
  type        = string
  nullable    = false
}

variable "qqbot_client_secret_arn" {
  description = "ARN of the Secrets Manager secret containing JSON key QQBOT_CLIENT_SECRET."
  type        = string
  nullable    = false
}

variable "dynamodb_jobs_table_name" {
  description = "Name of the DynamoDB jobs table exposed to the OpenClaw Agent."
  type        = string
  nullable    = false
}

variable "dynamodb_alerts_table_name" {
  description = "Name of the DynamoDB alerts table exposed to the OpenClaw Agent."
  type        = string
  nullable    = false
}

variable "dynamodb_reports_table_name" {
  description = "Name of the DynamoDB reports table exposed to the OpenClaw Agent."
  type        = string
  nullable    = false
}

variable "s3_report_bucket_name" {
  description = "Name of the S3 bucket used for reports, archives, and evidence."
  type        = string
  nullable    = false
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic used for project notifications."
  type        = string
  nullable    = false
}


variable "alert_require_payload" {
  description = "Whether alert_analysis rejects events without a structured alert payload."
  type        = bool
  default     = true
  nullable    = false
}

variable "alert_persist_dynamodb" {
  description = "Whether successful alert_analysis results are persisted in DynamoDB Alerts."
  type        = bool
  default     = true
  nullable    = false
}

variable "sns_notifications_enabled" {
  description = "Whether the ECS entrypoint publishes allowlisted post-task notifications to the project SNS topic."
  type        = bool
  default     = true
  nullable    = false
}

variable "sns_notifications_strict" {
  description = "Whether a notification delivery failure should fail an otherwise successful ECS task."
  type        = bool
  default     = false
  nullable    = false
}

variable "task_cpu" {
  description = "Fargate task CPU units. The current project baseline is 1024 units (1 vCPU)."
  type        = number
  default     = 1024
  nullable    = false

  validation {
    condition     = var.task_cpu == 1024
    error_message = "The current OpenClaw-AWS baseline requires task_cpu = 1024 (1 vCPU)."
  }
}

variable "task_memory" {
  description = "Fargate task memory in MiB. The current project baseline is 4096 MiB (4 GiB)."
  type        = number
  default     = 4096
  nullable    = false

  validation {
    condition     = var.task_memory == 4096
    error_message = "The current OpenClaw-AWS baseline requires task_memory = 4096 MiB (4 GiB)."
  }
}

variable "runtime_mount_path" {
  description = "Container path backed by the EFS access point."
  type        = string
  default     = "/app/runtime"
  nullable    = false

  validation {
    condition     = startswith(var.runtime_mount_path, "/")
    error_message = "runtime_mount_path must be an absolute Linux path."
  }
}

variable "container_insights_enabled" {
  description = "Whether to enable CloudWatch Container Insights on the ECS cluster."
  type        = bool
  default     = true
  nullable    = false
}

variable "qqbot_enabled" {
  description = "Whether to inject QQBot credentials and enable the QQBot channel."
  type        = bool
  default     = false
  nullable    = false
}

variable "qqbot_name" {
  description = "Display name used by the QQBot integration when enabled."
  type        = string
  default     = "OpenClaw QQBot"
  nullable    = false
}

variable "additional_environment_variables" {
  description = "Additional non-sensitive environment variables passed to the OpenClaw Agent container."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = length(setintersection(
      toset(keys(var.additional_environment_variables)),
      toset([
        "AWS_REGION",
        "AWS_DEFAULT_REGION",
        "OPENCLAW_ENVIRONMENT",
        "OPENCLAW_RUNTIME_DIR",
        "OPENCLAW_WORKSPACE",
        "OPENCLAW_TASK_TYPE",
        "OPENCLAW_JOB_ID",
        "OPENCLAW_TARGET",
        "OPENCLAW_PRIORITY",
        "DYNAMODB_JOBS_TABLE",
        "DYNAMODB_ALERTS_TABLE",
        "DYNAMODB_REPORTS_TABLE",
        "S3_REPORT_BUCKET",
        "SNS_TOPIC_ARN",
        "OPENCLAW_SNS_NOTIFY_ENABLED",
        "OPENCLAW_SNS_NOTIFY_STRICT",
        "OPENCLAW_ALERT_REQUIRE_PAYLOAD",
        "OPENCLAW_ALERT_PERSIST_DYNAMODB",
        "OPENCLAW_EFS_HISTORY_ENABLED",
        "OPENCLAW_EFS_HISTORY_STRICT",
        "OPENCLAW_EFS_HISTORY_DIR",
        "OPENCLAW_EFS_HISTORY_TASK_TYPES",
        "OPENCLAW_EFS_HISTORY_RETENTION_DAYS",
        "OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES",
        "OPENCLAW_REPORT_EFS_AGGREGATE",
        "OPENCLAW_REPORT_EFS_LOOKBACK_HOURS",
        "OPENCLAW_REPORT_EFS_MAX_ITEMS",
        "QQBOT_ENABLED",
        "QQBOT_NAME",
        "DEEPSEEK_API_KEY",
        "OPENCLAW_GATEWAY_TOKEN",
        "QQBOT_APP_ID",
        "QQBOT_CLIENT_SECRET"
      ])
    )) == 0

    error_message = "additional_environment_variables must not override reserved OpenClaw-AWS runtime or secret variable names."
  }
}

variable "efs_history_enabled" {
  description = "Whether completed task results are sanitized and archived to the EFS-backed history directory."
  type        = bool
  default     = true
  nullable    = false
}

variable "efs_history_strict" {
  description = "Whether an EFS history archival failure should fail an otherwise successful ECS task."
  type        = bool
  default     = false
  nullable    = false
}

variable "efs_history_task_types" {
  description = "Task types eligible for sanitized EFS history archival and report aggregation."
  type        = set(string)
  default = [
    "alert_analysis",
    "daily_inspection",
    "cost_inspection"
  ]
  nullable = false

  validation {
    condition = (
      length(var.efs_history_task_types) > 0 &&
      length(setsubtract(
        var.efs_history_task_types,
        toset([
          "healthcheck",
          "alert_analysis",
          "daily_inspection",
          "cost_inspection"
        ])
      )) == 0
    )
    error_message = "efs_history_task_types may contain only healthcheck, alert_analysis, daily_inspection, and cost_inspection."
  }
}

variable "efs_history_retention_days" {
  description = "Number of days sanitized EFS task history is retained."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.efs_history_retention_days >= 1 && var.efs_history_retention_days <= 365
    error_message = "efs_history_retention_days must be between 1 and 365."
  }
}

variable "efs_history_max_file_bytes" {
  description = "Maximum JSON file size accepted by the EFS history store and aggregator."
  type        = number
  default     = 262144
  nullable    = false

  validation {
    condition     = var.efs_history_max_file_bytes >= 4096 && var.efs_history_max_file_bytes <= 1048576
    error_message = "efs_history_max_file_bytes must be between 4096 and 1048576."
  }
}

variable "report_efs_aggregate_enabled" {
  description = "Whether report generation uses recent sanitized EFS history when explicit report input is absent."
  type        = bool
  default     = true
  nullable    = false
}

variable "report_efs_lookback_hours" {
  description = "Recent EFS history window used by automatic report aggregation."
  type        = number
  default     = 168
  nullable    = false

  validation {
    condition     = var.report_efs_lookback_hours >= 1 && var.report_efs_lookback_hours <= 2160
    error_message = "report_efs_lookback_hours must be between 1 and 2160."
  }
}

variable "report_efs_max_items" {
  description = "Maximum number of recent EFS history records included in one aggregated report."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition     = var.report_efs_max_items >= 1 && var.report_efs_max_items <= 500
    error_message = "report_efs_max_items must be between 1 and 500."
  }
}
