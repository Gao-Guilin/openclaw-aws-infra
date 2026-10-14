variable "aws_region" {
  description = "AWS Region in which the Terraform State bucket is created."
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name used when constructing resource names and tags."
  type        = string
  default     = "openclaw-aws"
}

variable "environment" {
  description = "Environment associated with the remote Terraform State."
  type        = string
  default     = "dev"
}
