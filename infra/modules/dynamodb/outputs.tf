output "table_names" {
  description = "Map of DynamoDB table names."
  value = {
    for key, table in aws_dynamodb_table.this :
    key => table.name
  }
}

output "table_arns" {
  description = "Map of DynamoDB table ARNs."
  value = {
    for key, table in aws_dynamodb_table.this :
    key => table.arn
  }
}

output "jobs_table_name" {
  description = "Name of the jobs DynamoDB table."
  value       = aws_dynamodb_table.this["jobs"].name
}

output "jobs_table_arn" {
  description = "ARN of the jobs DynamoDB table."
  value       = aws_dynamodb_table.this["jobs"].arn
}

output "alerts_table_name" {
  description = "Name of the alerts DynamoDB table."
  value       = aws_dynamodb_table.this["alerts"].name
}

output "alerts_table_arn" {
  description = "ARN of the alerts DynamoDB table."
  value       = aws_dynamodb_table.this["alerts"].arn
}

output "reports_table_name" {
  description = "Name of the reports DynamoDB table."
  value       = aws_dynamodb_table.this["reports"].name
}

output "reports_table_arn" {
  description = "ARN of the reports DynamoDB table."
  value       = aws_dynamodb_table.this["reports"].arn
}
