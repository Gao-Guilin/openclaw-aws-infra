variable "name_prefix" {
  description = "Common name prefix for DynamoDB tables."
  type        = string
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt DynamoDB tables."
  type        = string
  nullable    = false
}

variable "point_in_time_recovery_enabled" {
  description = "Whether point-in-time recovery is enabled."
  type        = bool
  default     = true
  nullable    = false
}

variable "deletion_protection_enabled" {
  description = "Whether DynamoDB deletion protection is enabled."
  type        = bool
  default     = false
  nullable    = false
}

variable "ttl_enabled" {
  description = "Whether DynamoDB TTL is enabled."
  type        = bool
  default     = true
  nullable    = false
}

variable "ttl_attribute_name" {
  description = "Attribute containing the Unix expiration timestamp."
  type        = string
  default     = "expires_at"
  nullable    = false
}
