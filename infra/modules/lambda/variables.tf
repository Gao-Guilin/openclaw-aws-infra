variable "name_prefix" {
  description = "Common name prefix for Lambda resources."
  type        = string
  nullable    = false
}


variable "environment" {
  description = "Deployment environment recorded in Jobs lifecycle items."
  type        = string
  nullable    = false
}

variable "job_receiver_role_arn" {
  description = "ARN of the IAM runtime role used by the job receiver Lambda."
  type        = string
  nullable    = false
}

variable "authorizer_role_arn" {
  description = "ARN of the IAM runtime role used by the API authorizer Lambda."
  type        = string
  nullable    = false
}

variable "job_receiver_log_group_name" {
  description = "Name of the pre-created CloudWatch log group used by the job receiver Lambda."
  type        = string
  nullable    = false
}

variable "authorizer_log_group_name" {
  description = "Name of the pre-created CloudWatch log group used by the API authorizer Lambda."
  type        = string
  nullable    = false
}

variable "jobs_table_name" {
  description = "Name of the DynamoDB table that stores job records."
  type        = string
  nullable    = false
}

variable "state_machine_arn" {
  description = "ARN of the Step Functions workflow started by the job receiver Lambda."
  type        = string
  nullable    = false
}

variable "quick_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret containing JSON key QUICK_API_KEY."
  type        = string
  nullable    = false
}

variable "lambda_runtime" {
  description = "Managed Python runtime used by both Lambda functions."
  type        = string
  default     = "python3.13"
  nullable    = false

  validation {
    condition     = contains(["python3.13", "python3.14"], var.lambda_runtime)
    error_message = "lambda_runtime must be python3.13 or python3.14."
  }
}

variable "job_receiver_memory_size" {
  description = "Memory allocated to the job receiver Lambda in MiB."
  type        = number
  default     = 256
  nullable    = false

  validation {
    condition     = var.job_receiver_memory_size >= 128 && var.job_receiver_memory_size <= 1024
    error_message = "job_receiver_memory_size must be between 128 and 1024 MiB."
  }
}

variable "authorizer_memory_size" {
  description = "Memory allocated to the API authorizer Lambda in MiB."
  type        = number
  default     = 256
  nullable    = false

  validation {
    condition     = var.authorizer_memory_size >= 128 && var.authorizer_memory_size <= 1024
    error_message = "authorizer_memory_size must be between 128 and 1024 MiB."
  }
}

variable "job_receiver_timeout_seconds" {
  description = "Maximum execution time of the job receiver Lambda."
  type        = number
  default     = 15
  nullable    = false

  validation {
    condition     = var.job_receiver_timeout_seconds >= 3 && var.job_receiver_timeout_seconds <= 60
    error_message = "job_receiver_timeout_seconds must be between 3 and 60 seconds."
  }
}

variable "authorizer_timeout_seconds" {
  description = "Maximum execution time of the API authorizer Lambda."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.authorizer_timeout_seconds >= 3 && var.authorizer_timeout_seconds <= 30
    error_message = "authorizer_timeout_seconds must be between 3 and 30 seconds."
  }
}

variable "job_retention_days" {
  description = "Number of days job records remain before DynamoDB TTL can remove them."
  type        = number
  default     = 90
  nullable    = false

  validation {
    condition     = var.job_retention_days >= 1 && var.job_retention_days <= 365
    error_message = "job_retention_days must be between 1 and 365."
  }
}

variable "authorizer_secret_cache_seconds" {
  description = "Number of seconds a warm authorizer execution environment caches the Quick API key."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition = (
      var.authorizer_secret_cache_seconds >= 0 &&
      var.authorizer_secret_cache_seconds <= 300
    )

    error_message = "authorizer_secret_cache_seconds must be between 0 and 300 seconds."
  }
}

variable "application_log_level" {
  description = "Application log level used by both Lambda functions."
  type        = string
  default     = "INFO"
  nullable    = false

  validation {
    condition     = contains(["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"], var.application_log_level)
    error_message = "application_log_level must be TRACE, DEBUG, INFO, WARN, ERROR, or FATAL."
  }
}

variable "system_log_level" {
  description = "Lambda platform log level used by both functions."
  type        = string
  default     = "WARN"
  nullable    = false

  validation {
    condition     = contains(["DEBUG", "INFO", "WARN"], var.system_log_level)
    error_message = "system_log_level must be DEBUG, INFO, or WARN."
  }
}


variable "operational_alarms_enabled" {
  description = "Whether to create the job receiver error alarm."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_period_seconds" {
  description = "Metric period used by the job receiver error alarm."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = contains([60, 300, 900], var.alarm_period_seconds)
    error_message = "alarm_period_seconds must be 60, 300, or 900."
  }
}
