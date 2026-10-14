variable "name_prefix" {
  description = "Common name prefix for SNS resources."
  type        = string
  nullable    = false
}

variable "aws_region" {
  description = "AWS Region in which the SNS topic is created."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the SNS topic."
  type        = string
  nullable    = false
}


variable "email_subscriptions" {
  description = "Email endpoints subscribed to budget, alert, report, and task-failure notifications."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for value in var.email_subscriptions : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", value))])
    error_message = "Every email_subscriptions entry must be a valid email address."
  }
}
