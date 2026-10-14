variable "name_prefix" {
  description = "Common name prefix for API Gateway resources."
  type        = string
  nullable    = false
}

variable "job_receiver_invoke_arn" {
  description = "Invoke ARN of the Lambda job receiver integration."
  type        = string
  nullable    = false
}

variable "job_receiver_function_name" {
  description = "Name of the Lambda job receiver function used in the API Gateway invoke permission."
  type        = string
  nullable    = false
}

variable "authorizer_invoke_arn" {
  description = "Invoke ARN of the Lambda API authorizer."
  type        = string
  nullable    = false
}

variable "authorizer_function_name" {
  description = "Name of the Lambda API authorizer function used in the API Gateway invoke permission."
  type        = string
  nullable    = false
}

variable "access_log_group_arn" {
  description = "ARN of the pre-created CloudWatch log group used for HTTP API access logs."
  type        = string
  nullable    = false
}

variable "integration_timeout_milliseconds" {
  description = "Maximum time API Gateway waits for the Lambda job receiver integration."
  type        = number
  default     = 20000
  nullable    = false

  validation {
    condition = (
      var.integration_timeout_milliseconds >= 50 &&
      var.integration_timeout_milliseconds <= 30000
    )

    error_message = "integration_timeout_milliseconds must be between 50 and 30000 milliseconds."
  }
}

variable "authorizer_result_ttl_seconds" {
  description = "API Gateway authorizer result cache TTL. Zero forces authorization on every request."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition = (
      var.authorizer_result_ttl_seconds >= 0 &&
      var.authorizer_result_ttl_seconds <= 3600
    )

    error_message = "authorizer_result_ttl_seconds must be between 0 and 3600 seconds."
  }
}

variable "throttling_burst_limit" {
  description = "Maximum burst of requests allowed by the default HTTP API stage."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.throttling_burst_limit >= 1 && var.throttling_burst_limit <= 100
    error_message = "throttling_burst_limit must be between 1 and 100."
  }
}

variable "throttling_rate_limit" {
  description = "Steady-state request rate allowed by the default HTTP API stage."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.throttling_rate_limit >= 1 && var.throttling_rate_limit <= 100
    error_message = "throttling_rate_limit must be between 1 and 100 requests per second."
  }
}

variable "detailed_metrics_enabled" {
  description = "Whether API Gateway publishes detailed route metrics."
  type        = bool
  default     = true
  nullable    = false
}


variable "operational_alarms_enabled" {
  description = "Whether to create the HTTP API 5xx alarm."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_period_seconds" {
  description = "Metric period used by the HTTP API 5xx alarm."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = contains([60, 300, 900], var.alarm_period_seconds)
    error_message = "alarm_period_seconds must be 60, 300, or 900."
  }
}
