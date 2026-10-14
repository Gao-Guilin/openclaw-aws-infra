output "api_id" {
  description = "ID of the OpenClaw-AWS HTTP API."
  value       = aws_apigatewayv2_api.this.id
}

output "api_name" {
  description = "Name of the OpenClaw-AWS HTTP API."
  value       = aws_apigatewayv2_api.this.name
}

output "api_endpoint" {
  description = "Base HTTPS endpoint of the OpenClaw-AWS HTTP API."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "api_execution_arn" {
  description = "Execution ARN of the OpenClaw-AWS HTTP API."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "jobs_endpoint" {
  description = "Protected POST endpoint used by Amazon Quick to submit jobs."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/jobs"
}

output "route_key" {
  description = "Route key exposed by the HTTP API."
  value       = aws_apigatewayv2_route.jobs.route_key
}

output "stage_name" {
  description = "Name of the auto-deployed API Gateway stage."
  value       = aws_apigatewayv2_stage.default.name
}

output "authorizer_id" {
  description = "ID of the Lambda request authorizer."
  value       = aws_apigatewayv2_authorizer.quick_api_key.id
}

output "authorizer_name" {
  description = "Name of the Lambda request authorizer."
  value       = aws_apigatewayv2_authorizer.quick_api_key.name
}

output "integration_id" {
  description = "ID of the Lambda proxy integration."
  value       = aws_apigatewayv2_integration.job_receiver.id
}


output "api_gateway_5xx_alarm_name" {
  description = "Name of the API Gateway 5xx alarm, or null when disabled."
  value       = try(aws_cloudwatch_metric_alarm.api_gateway_5xx[0].alarm_name, null)
}

output "api_gateway_5xx_alarm_arn" {
  description = "ARN of the API Gateway 5xx alarm, or null when disabled."
  value       = try(aws_cloudwatch_metric_alarm.api_gateway_5xx[0].arn, null)
}
