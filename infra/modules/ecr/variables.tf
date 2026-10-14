variable "name_prefix" {
  description = "Common name prefix for ECR resources."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the customer managed KMS key used to encrypt the ECR repository."
  type        = string
  nullable    = false
}

variable "scan_on_push" {
  description = "Whether ECR scans container images after they are pushed."
  type        = bool
  default     = true
  nullable    = false
}

variable "force_delete" {
  description = "Whether Terraform may delete the repository when it still contains images."
  type        = bool
  default     = true
  nullable    = false
}

variable "max_image_count" {
  description = "Maximum number of images retained in the repository."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.max_image_count >= 1
    error_message = "max_image_count must be at least 1."
  }
}

variable "untagged_image_expiration_days" {
  description = "Number of days before untagged images are deleted."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.untagged_image_expiration_days >= 1
    error_message = "untagged_image_expiration_days must be at least 1."
  }
}
