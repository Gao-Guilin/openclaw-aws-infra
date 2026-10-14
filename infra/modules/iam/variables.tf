variable "name_prefix" {
  description = "Common name prefix for IAM resources."
  type        = string
  nullable    = false
}

variable "aws_region" {
  description = "AWS Region used by regional IAM policy conditions."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the project KMS key."
  type        = string
  nullable    = false
}

variable "ecr_repository_arn" {
  description = "ARN of the OpenClaw Agent ECR repository."
  type        = string
  nullable    = false
}


variable "additional_ecr_repository_arns" {
  description = "Additional ECR repositories that ECS may pull from during controlled environment bootstrap or promotion."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "quick_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret that stores the Quick API key."
  type        = string
  nullable    = false
}

variable "secret_arns" {
  description = "Map of Secrets Manager secret ARNs."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([
      for key in [
        "deepseek_api_key",
        "openclaw_gateway_token",
        "qqbot_app_id",
        "qqbot_client_secret"
      ] : contains(keys(var.secret_arns), key)
    ])

    error_message = "secret_arns must contain all four OpenClaw secret keys."
  }
}

variable "cloudwatch_log_group_arns" {
  description = "Map of CloudWatch log group ARNs."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([
      for key in [
        "ecs_agent",
        "lambda_job_receiver",
        "lambda_authorizer",
        "step_functions",
        "api_gateway",
        "eventbridge_pipes"
      ] : contains(keys(var.cloudwatch_log_group_arns), key)
    ])

    error_message = "cloudwatch_log_group_arns must contain the ECS, both Lambda, Step Functions, API Gateway, and EventBridge Pipes log groups."
  }
}

variable "s3_bucket_arn" {
  description = "ARN of the OpenClaw reports and archive S3 bucket."
  type        = string
  nullable    = false
}

variable "dynamodb_table_arns" {
  description = "Map of OpenClaw DynamoDB table ARNs."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([
      for key in ["jobs", "alerts", "reports"] :
      contains(keys(var.dynamodb_table_arns), key)
    ])

    error_message = "dynamodb_table_arns must contain jobs, alerts, and reports."
  }
}

variable "sns_topic_arn" {
  description = "ARN of the OpenClaw notification SNS topic."
  type        = string
  nullable    = false
}

variable "sqs_queue_arns" {
  description = "Map of high, medium, and low priority SQS queue ARNs."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([
      for key in ["high", "medium", "low"] :
      contains(keys(var.sqs_queue_arns), key)
    ])

    error_message = "sqs_queue_arns must contain high, medium, and low priority queues."
  }
}
