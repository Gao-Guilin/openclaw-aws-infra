variable "name_prefix" {
  description = "Common name prefix for KMS resources."
  type        = string
  nullable    = false
}

variable "deletion_window_in_days" {
  description = "Waiting period before a scheduled KMS key deletion."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition = (
      var.deletion_window_in_days >= 7 &&
      var.deletion_window_in_days <= 30
    )

    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "enable_key_rotation" {
  description = "Whether automatic KMS key rotation is enabled."
  type        = bool
  default     = true
  nullable    = false
}

variable "aws_region" {
  description = "AWS Region in which the KMS key is used."
  type        = string
  nullable    = false
}
