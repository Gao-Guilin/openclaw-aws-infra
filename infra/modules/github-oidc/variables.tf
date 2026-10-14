variable "name_prefix" {
  type     = string
  nullable = false
}

variable "project_resource_prefix" {
  type     = string
  nullable = false
}

variable "aws_region" {
  description = "AWS Region used to scope environment resource ARNs."
  type        = string
  default     = "ap-northeast-1"
  nullable    = false
}

variable "environment_name" {
  description = "Environment controlled by this module call. Defaults to the final name_prefix segment."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.environment_name == null || contains(["dev", "prod"], var.environment_name)
    error_message = "environment_name must be dev, prod, or null."
  }
}

variable "github_repository" {
  type     = string
  nullable = false

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must use owner/repository format."
  }
}

variable "github_branch_patterns" {
  type     = set(string)
  nullable = false
}

variable "github_environment_names" {
  type     = set(string)
  default  = []
  nullable = false
}

variable "oidc_provider_arn" {
  description = "ARN of the account-level GitHub Actions OIDC provider managed by infra/bootstrap/github-oidc."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the GitHub Actions OIDC provider ARN."
  }
}

variable "ecr_repository_arn" {
  type     = string
  nullable = false
}

variable "additional_ecr_repository_arns" {
  type     = list(string)
  default  = []
  nullable = false
}

variable "terraform_deploy_enabled" {
  type     = bool
  default  = true
  nullable = false
}

variable "terraform_state_bucket" {
  type     = string
  nullable = false
}

variable "terraform_state_key" {
  description = "Exact remote State key for this environment. Defaults to envs/<environment>/terraform.tfstate."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.terraform_state_key == null || can(regex("^[A-Za-z0-9._/-]+terraform\\.tfstate$", var.terraform_state_key))
    error_message = "terraform_state_key must be a valid path ending in terraform.tfstate."
  }
}
