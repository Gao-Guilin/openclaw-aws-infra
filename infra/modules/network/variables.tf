variable "name_prefix" {
  description = "Common name prefix for network resources."
  type        = string
  nullable    = false
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block used by the project VPC."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "IPv4 CIDR blocks for the two public subnets."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.public_subnet_cidrs) == 2 &&
      length(distinct(var.public_subnet_cidrs)) == 2 &&
      alltrue([
        for cidr in var.public_subnet_cidrs :
        can(cidrnetmask(cidr))
      ])
    )

    error_message = "public_subnet_cidrs must contain exactly two different valid IPv4 CIDR blocks."
  }
}
