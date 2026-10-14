variable "name_prefix" {
  description = "Common name prefix for Secrets Manager resources."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the customer managed KMS key used to encrypt secrets."
  type        = string
  nullable    = false
}

variable "recovery_window_in_days" {
  description = "Number of days Secrets Manager waits before permanently deleting a secret."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition = (
      var.recovery_window_in_days >= 7 &&
      var.recovery_window_in_days <= 30
    )

    error_message = "recovery_window_in_days must be between 7 and 30."
  }
}
