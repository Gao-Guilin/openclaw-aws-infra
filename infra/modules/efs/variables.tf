variable "name_prefix" {
  description = "Common name prefix for EFS resources."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the EFS file system."
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "Subnet IDs in which EFS mount targets are created."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.subnet_ids) == 2 &&
      length(distinct(var.subnet_ids)) == 2
    )

    error_message = "subnet_ids must contain exactly two different subnet IDs."
  }
}

variable "security_group_id" {
  description = "Security group ID assigned to EFS mount targets."
  type        = string
  nullable    = false
}

variable "access_point_path" {
  description = "Root directory exposed through the EFS access point."
  type        = string
  default     = "/openclaw-runtime"
  nullable    = false

  validation {
    condition     = startswith(var.access_point_path, "/")
    error_message = "access_point_path must start with a forward slash."
  }
}

variable "posix_user_id" {
  description = "POSIX user ID enforced by the EFS access point."
  type        = number
  default     = 1000
  nullable    = false
}

variable "posix_group_id" {
  description = "POSIX group ID enforced by the EFS access point."
  type        = number
  default     = 1000
  nullable    = false
}

variable "root_directory_permissions" {
  description = "POSIX permissions used when creating the access point root directory."
  type        = string
  default     = "0750"
  nullable    = false

  validation {
    condition     = can(regex("^[0-7]{3,4}$", var.root_directory_permissions))
    error_message = "root_directory_permissions must be a valid three-digit or four-digit POSIX permission value."
  }
}
