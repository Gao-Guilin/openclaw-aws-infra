variable "aws_region" {
  description = "AWS Region used by the provider. IAM itself is account-global."
  type        = string
  default     = "ap-northeast-1"
  nullable    = false
}
