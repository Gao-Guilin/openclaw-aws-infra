output "job_receiver_function_name" {
  description = "Name of the Lambda job receiver function."
  value       = aws_lambda_function.job_receiver.function_name
}

output "job_receiver_function_arn" {
  description = "ARN of the Lambda job receiver function."
  value       = aws_lambda_function.job_receiver.arn
}

output "job_receiver_invoke_arn" {
  description = "Invoke ARN used by API Gateway to call the job receiver Lambda."
  value       = aws_lambda_function.job_receiver.invoke_arn
}

output "authorizer_function_name" {
  description = "Name of the Lambda API authorizer function."
  value       = aws_lambda_function.authorizer.function_name
}

output "authorizer_function_arn" {
  description = "ARN of the Lambda API authorizer function."
  value       = aws_lambda_function.authorizer.arn
}

output "authorizer_invoke_arn" {
  description = "Invoke ARN used by API Gateway to call the Lambda authorizer."
  value       = aws_lambda_function.authorizer.invoke_arn
}

output "lambda_runtime" {
  description = "Managed Python runtime used by both Lambda functions."
  value       = var.lambda_runtime
}

output "job_receiver_source_code_hash" {
  description = "Base64-encoded SHA-256 hash of the job receiver deployment package."
  value       = data.archive_file.job_receiver.output_base64sha256
}

output "authorizer_source_code_hash" {
  description = "Base64-encoded SHA-256 hash of the authorizer deployment package."
  value       = data.archive_file.authorizer.output_base64sha256
}


output "job_receiver_error_alarm_name" {
  description = "Name of the job receiver Lambda error alarm, or null when disabled."
  value       = try(aws_cloudwatch_metric_alarm.job_receiver_errors[0].alarm_name, null)
}

output "job_receiver_error_alarm_arn" {
  description = "ARN of the job receiver Lambda error alarm, or null when disabled."
  value       = try(aws_cloudwatch_metric_alarm.job_receiver_errors[0].arn, null)
}
