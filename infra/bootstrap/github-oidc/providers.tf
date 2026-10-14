provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "openclaw-aws"
      ManagedBy = "terraform"
      Scope     = "account-shared"
    }
  }
}
