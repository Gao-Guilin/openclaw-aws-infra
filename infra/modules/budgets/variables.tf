variable "name_prefix" {
  description = "Common name prefix for AWS Budgets resources."
  type        = string
  nullable    = false
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic that receives budget notifications."
  type        = string
  nullable    = false
}

variable "monthly_budget_limit_usd" {
  description = "Monthly account cost budget limit in USD."
  type        = number
  nullable    = false

  validation {
    condition     = var.monthly_budget_limit_usd > 0
    error_message = "monthly_budget_limit_usd must be greater than zero."
  }
}

variable "forecasted_warning_threshold" {
  description = "Forecasted cost percentage that triggers an early warning."
  type        = number
  default     = 80
  nullable    = false

  validation {
    condition = (
      var.forecasted_warning_threshold > 0 &&
      var.forecasted_warning_threshold <= 1000
    )

    error_message = "forecasted_warning_threshold must be between 1 and 1000."
  }
}

variable "actual_warning_threshold" {
  description = "Actual cost percentage that triggers a warning."
  type        = number
  default     = 80
  nullable    = false

  validation {
    condition = (
      var.actual_warning_threshold > 0 &&
      var.actual_warning_threshold <= 1000
    )

    error_message = "actual_warning_threshold must be between 1 and 1000."
  }
}

variable "actual_limit_threshold" {
  description = "Actual cost percentage that triggers the limit-exceeded notification."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition = (
      var.actual_limit_threshold > 0 &&
      var.actual_limit_threshold <= 1000
    )

    error_message = "actual_limit_threshold must be between 1 and 1000."
  }
}
