variable "name_prefix" {
  description = "Common name prefix for CloudWatch resources."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt CloudWatch log groups."
  type        = string
  nullable    = false
}

variable "log_retention_days" {
  description = "Number of days CloudWatch Logs retains log events."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365],
      var.log_retention_days
    )

    error_message = "log_retention_days must be a supported CloudWatch Logs retention value."
  }
}
