variable "name_prefix" {
  description = "Common name prefix for S3 resources."
  type        = string
  nullable    = false
}

variable "aws_region" {
  description = "AWS Region in which the S3 bucket is created."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt S3 objects."
  type        = string
  nullable    = false
}

variable "force_destroy" {
  description = "Whether Terraform may delete the bucket when it contains objects."
  type        = bool
  default     = true
  nullable    = false
}


variable "current_version_expiration_days" {
  description = "Number of days before current report, archive, and evidence objects expire."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition     = var.current_version_expiration_days >= 1
    error_message = "current_version_expiration_days must be at least 1."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days before noncurrent object versions are deleted."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Number of days before incomplete multipart uploads are removed."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.abort_incomplete_multipart_upload_days >= 1
    error_message = "abort_incomplete_multipart_upload_days must be at least 1."
  }
}
