variable "name_prefix" {
  description = "Common name prefix for Step Functions resources."
  type        = string
  nullable    = false
}

variable "role_arn" {
  description = "ARN of the IAM execution role used by the state machine."
  type        = string
  nullable    = false
}

variable "cloudwatch_log_group_arn" {
  description = "ARN of the pre-created CloudWatch log group used for Step Functions execution logs."
  type        = string
  nullable    = false
}

variable "sqs_queue_urls" {
  description = "Map containing the high, medium, and low priority SQS queue URLs."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([
      contains(keys(var.sqs_queue_urls), "high"),
      contains(keys(var.sqs_queue_urls), "medium"),
      contains(keys(var.sqs_queue_urls), "low")
    ])

    error_message = "sqs_queue_urls must contain high, medium, and low keys."
  }
}

variable "execution_timeout_seconds" {
  description = "Maximum runtime of one routing workflow execution."
  type        = number
  default     = 120
  nullable    = false

  validation {
    condition     = var.execution_timeout_seconds >= 30 && var.execution_timeout_seconds <= 900
    error_message = "execution_timeout_seconds must be between 30 and 900 seconds."
  }
}

variable "log_level" {
  description = "CloudWatch Logs level for the state machine."
  type        = string
  default     = "ALL"
  nullable    = false

  validation {
    condition     = contains(["ALL", "ERROR", "FATAL", "OFF"], var.log_level)
    error_message = "log_level must be ALL, ERROR, FATAL, or OFF."
  }
}

variable "include_execution_data" {
  description = "Whether Step Functions execution input and output are included in CloudWatch Logs."
  type        = bool
  default     = true
  nullable    = false
}
