output "log_group_names" {
  description = "Map of CloudWatch log group names."
  value = {
    for key, log_group in aws_cloudwatch_log_group.this :
    key => log_group.name
  }
}

output "log_group_arns" {
  description = "Map of CloudWatch log group ARNs."
  value = {
    for key, log_group in aws_cloudwatch_log_group.this :
    key => log_group.arn
  }
}

output "ecs_agent_log_group_name" {
  description = "CloudWatch log group name used by ECS agent tasks."
  value       = aws_cloudwatch_log_group.this["ecs_agent"].name
}

output "lambda_job_receiver_log_group_name" {
  description = "CloudWatch log group name used by the job receiver Lambda."
  value       = aws_cloudwatch_log_group.this["lambda_job_receiver"].name
}

output "lambda_authorizer_log_group_name" {
  description = "CloudWatch log group name used by the API authorizer Lambda."
  value       = aws_cloudwatch_log_group.this["lambda_authorizer"].name
}

output "lambda_authorizer_log_group_arn" {
  description = "CloudWatch log group ARN used by the API authorizer Lambda."
  value       = aws_cloudwatch_log_group.this["lambda_authorizer"].arn
}

output "step_functions_log_group_arn" {
  description = "CloudWatch log group ARN used by Step Functions."
  value       = aws_cloudwatch_log_group.this["step_functions"].arn
}

output "api_gateway_log_group_arn" {
  description = "CloudWatch log group ARN used for API Gateway access logs."
  value       = aws_cloudwatch_log_group.this["api_gateway"].arn
}

output "eventbridge_pipes_log_group_name" {
  description = "CloudWatch log group name used by EventBridge Pipes."
  value       = aws_cloudwatch_log_group.this["eventbridge_pipes"].name
}

output "eventbridge_pipes_log_group_arn" {
  description = "CloudWatch log group ARN used by EventBridge Pipes."
  value       = aws_cloudwatch_log_group.this["eventbridge_pipes"].arn
}
