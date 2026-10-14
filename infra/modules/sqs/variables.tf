variable "name_prefix" {
  description = "Common name prefix for SQS resources."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt SQS queues."
  type        = string
  nullable    = false
}

variable "visibility_timeout_seconds" {
  description = "Length of time a received message remains invisible to other consumers."
  type        = number
  default     = 900
  nullable    = false

  validation {
    condition = (
      var.visibility_timeout_seconds >= 0 &&
      var.visibility_timeout_seconds <= 43200
    )

    error_message = "visibility_timeout_seconds must be between 0 and 43200."
  }
}

variable "message_retention_seconds" {
  description = "Number of seconds messages remain in priority queues."
  type        = number
  default     = 345600
  nullable    = false

  validation {
    condition = (
      var.message_retention_seconds >= 60 &&
      var.message_retention_seconds <= 1209600
    )

    error_message = "message_retention_seconds must be between 60 and 1209600."
  }
}

variable "dlq_message_retention_seconds" {
  description = "Number of seconds messages remain in dead-letter queues."
  type        = number
  default     = 1209600
  nullable    = false

  validation {
    condition = (
      var.dlq_message_retention_seconds >= 60 &&
      var.dlq_message_retention_seconds <= 1209600 &&
      var.dlq_message_retention_seconds >= var.message_retention_seconds
    )

    error_message = "dlq_message_retention_seconds must be between 60 and 1209600 and must not be shorter than message_retention_seconds."
  }
}

variable "receive_wait_time_seconds" {
  description = "Long polling wait time for receiving messages."
  type        = number
  default     = 20
  nullable    = false

  validation {
    condition = (
      var.receive_wait_time_seconds >= 0 &&
      var.receive_wait_time_seconds <= 20
    )

    error_message = "receive_wait_time_seconds must be between 0 and 20."
  }
}

variable "max_receive_count" {
  description = "Number of failed receives before a message is moved to its DLQ."
  type        = number
  default     = 3
  nullable    = false

  validation {
    condition     = var.max_receive_count >= 1
    error_message = "max_receive_count must be at least 1."
  }
}

variable "kms_data_key_reuse_period_seconds" {
  description = "Length of time SQS reuses a KMS data key."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition = (
      var.kms_data_key_reuse_period_seconds >= 60 &&
      var.kms_data_key_reuse_period_seconds <= 86400
    )

    error_message = "kms_data_key_reuse_period_seconds must be between 60 and 86400."
  }
}
