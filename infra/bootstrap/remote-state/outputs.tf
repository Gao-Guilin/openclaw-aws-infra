output "state_bucket_name" {
  description = "Name of the S3 bucket used to store Terraform State."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket used to store Terraform State."
  value       = aws_s3_bucket.terraform_state.arn
}

output "state_bucket_region" {
  description = "AWS Region containing the Terraform State bucket."
  value       = var.aws_region
}

output "dev_state_key" {
  description = "S3 object key reserved for the dev Terraform State."
  value       = "envs/dev/terraform.tfstate"
}
