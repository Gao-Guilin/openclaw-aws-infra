variable "aws_region" {
  description = "AWS Region used by the OpenClaw-AWS prod environment."
  type        = string
  default     = "ap-northeast-1"
  nullable    = false

  validation {
    condition     = var.aws_region == "ap-northeast-1"
    error_message = "The OpenClaw-AWS prod environment must be deployed in ap-northeast-1 (Tokyo)."
  }
}

variable "project_name" {
  description = "Project name used as the base prefix for AWS resource names and tags."
  type        = string
  default     = "openclaw-aws"
  nullable    = false

  validation {
    condition = (
      length(var.project_name) >= 3 &&
      length(var.project_name) <= 32 &&
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.project_name))
    )

    error_message = "project_name must be 3-32 characters and contain only lowercase letters, numbers, and hyphens. It must start and end with a letter or number."
  }
}

variable "environment" {
  description = "Deployment environment represented by this Terraform root module."
  type        = string
  default     = "prod"
  nullable    = false

  validation {
    condition     = var.environment == "prod"
    error_message = "This root module is infra/envs/prod, so environment must be prod."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block used by the OpenClaw-AWS VPC."
  type        = string
  default     = "10.30.0.0/16"
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "IPv4 CIDR blocks used by the two public subnets."
  type        = list(string)

  default = [
    "10.30.1.0/24",
    "10.30.2.0/24"
  ]

  nullable = false

  validation {
    condition = (
      length(var.public_subnet_cidrs) == 2 &&
      length(distinct(var.public_subnet_cidrs)) == 2 &&
      alltrue([
        for cidr in var.public_subnet_cidrs :
        can(cidrnetmask(cidr))
      ])
    )

    error_message = "public_subnet_cidrs must contain exactly two different valid IPv4 CIDR blocks."
  }
}

variable "monthly_budget_limit_usd" {
  description = "Monthly AWS account cost budget limit in USD."
  type        = number
  default     = 15
  nullable    = false

  validation {
    condition     = var.monthly_budget_limit_usd > 0
    error_message = "monthly_budget_limit_usd must be greater than zero."
  }
}

variable "additional_tags" {
  description = "Additional tags merged with the standard project tags."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "agent_image_digest" {
  description = "SHA-256 digest of the OpenClaw Agent image stored in ECR."
  type        = string
  default     = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  nullable    = false

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.agent_image_digest))
    error_message = "agent_image_digest must use the format sha256 followed by 64 lowercase hexadecimal characters."
  }
}

variable "ecs_task_cpu" {
  description = "CPU units assigned to each OpenClaw ECS Fargate task."
  type        = number
  default     = 1024
  nullable    = false

  validation {
    condition     = var.ecs_task_cpu == 1024
    error_message = "The current OpenClaw-AWS baseline requires ecs_task_cpu = 1024 (1 vCPU)."
  }
}

variable "ecs_task_memory" {
  description = "Memory in MiB assigned to each OpenClaw ECS Fargate task."
  type        = number
  default     = 4096
  nullable    = false

  validation {
    condition     = var.ecs_task_memory == 4096
    error_message = "The current OpenClaw-AWS baseline requires ecs_task_memory = 4096 MiB (4 GiB)."
  }
}

variable "qqbot_enabled" {
  description = "Whether the QQBot channel and its credentials are enabled in the ECS task definition."
  type        = bool
  default     = false
  nullable    = false
}

variable "eventbridge_pipes_enabled" {
  description = "Whether the three SQS-to-ECS EventBridge Pipes run after deployment."
  type        = bool
  default     = true
  nullable    = false
}

variable "eventbridge_scheduler_enabled" {
  description = "Whether the morning inspection, afternoon inspection, and weekly report schedules are enabled."
  type        = bool
  default     = false
  nullable    = false
}

variable "github_repository" {
  description = "GitHub repository allowed to deliver OpenClaw Agent images, in owner/repository format."
  type        = string
  default     = "YOUR_GITHUB_OWNER/openclaw-aws"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use the owner/repository format."
  }
}

variable "github_cd_branch_patterns" {
  description = "Git branches or branch patterns allowed to assume the GitHub Actions basic CD role."
  type        = set(string)

  default = [
    "main",
    "cd/*"
  ]

  nullable = false

  validation {
    condition = (
      length(var.github_cd_branch_patterns) > 0 &&
      alltrue([
        for branch in var.github_cd_branch_patterns :
        length(trimspace(branch)) > 0 &&
        !startswith(branch, "refs/") &&
        !strcontains(branch, ":")
      ])
    )

    error_message = "github_cd_branch_patterns must contain non-empty branch names or patterns without a refs/ prefix or colon."
  }
}

variable "efs_history_enabled" {
  description = "Whether completed runtime task results are sanitized and archived to EFS."
  type        = bool
  default     = true
  nullable    = false
}

variable "efs_history_strict" {
  description = "Whether EFS history archival failure fails an otherwise successful task."
  type        = bool
  default     = false
  nullable    = false
}

variable "efs_history_task_types" {
  description = "Task types included in sanitized EFS history and automatic report aggregation."
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
    error_message = "efs_history_task_types contains an unsupported task type."
  }
}

variable "efs_history_retention_days" {
  description = "Retention period for sanitized EFS task history."
  type        = number
  default     = 8
  nullable    = false

  validation {
    condition     = var.efs_history_retention_days >= 1 && var.efs_history_retention_days <= 365
    error_message = "efs_history_retention_days must be between 1 and 365."
  }
}

variable "efs_history_max_file_bytes" {
  description = "Maximum task-history JSON size accepted for EFS archival and aggregation."
  type        = number
  default     = 262144
  nullable    = false

  validation {
    condition     = var.efs_history_max_file_bytes >= 4096 && var.efs_history_max_file_bytes <= 1048576
    error_message = "efs_history_max_file_bytes must be between 4096 and 1048576."
  }
}

variable "report_efs_aggregate_enabled" {
  description = "Whether report_generation automatically aggregates recent EFS history when explicit input is absent."
  type        = bool
  default     = true
  nullable    = false
}

variable "report_efs_lookback_hours" {
  description = "Lookback window used by automatic EFS history report aggregation."
  type        = number
  default     = 168
  nullable    = false

  validation {
    condition     = var.report_efs_lookback_hours >= 1 && var.report_efs_lookback_hours <= 2160
    error_message = "report_efs_lookback_hours must be between 1 and 2160."
  }
}

variable "report_efs_max_items" {
  description = "Maximum EFS history records aggregated into one report."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition     = var.report_efs_max_items >= 1 && var.report_efs_max_items <= 500
    error_message = "report_efs_max_items must be between 1 and 500."
  }
}

variable "agent_image_uri_override" {
  description = "Optional complete image URI used only for controlled bootstrap. Empty means use this environment's ECR repository and agent_image_digest."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.agent_image_uri_override == "" || can(regex("^[^[:space:]]+(@sha256:[0-9a-f]{64}|:[^[:space:]]+)$", var.agent_image_uri_override))
    error_message = "agent_image_uri_override must be empty or a complete tagged/digest image URI."
  }
}

variable "additional_ecr_pull_repository_arns" {
  description = "Additional ECR repositories ECS may pull from during environment bootstrap."
  type        = list(string)
  default     = ["arn:aws:ecr:ap-northeast-1:000000000000:repository/openclaw-aws-dev-agent"]
  nullable    = false
}

variable "additional_cd_ecr_repository_arns" {
  description = "Additional ECR repositories the GitHub CD role may read/write for artifact promotion."
  type        = list(string)
  default     = ["arn:aws:ecr:ap-northeast-1:000000000000:repository/openclaw-aws-dev-agent"]
  nullable    = false
}

variable "cloudwatch_log_retention_days" {
  type     = number
  default  = 7
  nullable = false
}

variable "s3_current_object_expiration_days" {
  type     = number
  default  = 60
  nullable = false
}

variable "s3_force_destroy" {
  type     = bool
  default  = false
  nullable = false
}

variable "dynamodb_deletion_protection_enabled" {
  type     = bool
  default  = true
  nullable = false
}

variable "sns_email_subscriptions" {
  type     = list(string)
  default  = ["operator@example.com"]
  nullable = false
}

variable "alert_persist_dynamodb" {
  type     = bool
  default  = true
  nullable = false
}

variable "alert_ingress_enabled" {
  type     = bool
  default  = true
  nullable = false
}

variable "scheduler_timezone" {
  type     = string
  default  = "Asia/Shanghai"
  nullable = false
}

variable "morning_schedule_expression" {
  type     = string
  default  = "cron(0 9 * * ? *)"
  nullable = false
}

variable "afternoon_schedule_expression" {
  type     = string
  default  = "cron(0 16 * * ? *)"
  nullable = false
}

variable "weekly_report_schedule_expression" {
  type     = string
  default  = "cron(30 16 ? * TUE *)"
  nullable = false
}

variable "terraform_state_bucket" {
  type     = string
  default  = "openclaw-aws-terraform-state-000000000000-ap-northeast-1"
  nullable = false
}

variable "terraform_state_key" {
  description = "Exact S3 backend State key used by prod Plan and Apply roles."
  type        = string
  default     = "envs/prod/terraform.tfstate"
  nullable    = false

  validation {
    condition     = var.terraform_state_key == "envs/prod/terraform.tfstate"
    error_message = "The prod root module must use envs/prod/terraform.tfstate."
  }
}

variable "github_oidc_provider_arn" {
  description = "Account-level GitHub Actions OIDC provider managed by infra/bootstrap/github-oidc."
  type        = string
  default     = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com"
  nullable    = false
}

variable "github_environment_names" {
  type     = set(string)
  default  = ["prod"]
  nullable = false
}


variable "operational_alarms_enabled" {
  description = "Whether to create project operational CloudWatch alarms."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_period_seconds" {
  description = "Metric period for project operational alarms."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = contains([60, 300, 900], var.alarm_period_seconds)
    error_message = "alarm_period_seconds must be 60, 300, or 900."
  }
}
