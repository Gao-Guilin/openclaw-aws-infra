output "bucket_id" {
  description = "ID and name of the S3 bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_name" {
  description = "Name of the S3 bucket."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN of the S3 bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the S3 bucket."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "reports_prefix" {
  description = "S3 prefix used for generated reports."
  value       = "reports/"
}

output "archive_prefix" {
  description = "S3 prefix used for archived data."
  value       = "archive/"
}

output "evidence_prefix" {
  description = "S3 prefix used for deployment and testing evidence."
  value       = "evidence/"
}
