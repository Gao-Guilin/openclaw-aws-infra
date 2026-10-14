output "repository_name" {
  description = "Name of the ECR repository."
  value       = aws_ecr_repository.this.name
}

output "repository_arn" {
  description = "ARN of the ECR repository."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = "URL used to tag, push, and pull container images."
  value       = aws_ecr_repository.this.repository_url
}

output "registry_id" {
  description = "AWS account registry ID that owns the repository."
  value       = aws_ecr_repository.this.registry_id
}
