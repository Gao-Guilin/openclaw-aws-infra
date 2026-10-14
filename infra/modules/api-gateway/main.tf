locals {
  api_name        = "${var.name_prefix}-api"
  authorizer_name = "${var.name_prefix}-quick-api-key-authorizer"
  route_key       = "POST /jobs"
  stage_name      = "$default"

  access_log_format = jsonencode({
    requestId               = "$context.requestId"
    requestTime             = "$context.requestTime"
    routeKey                = "$context.routeKey"
    status                  = "$context.status"
    responseLength          = "$context.responseLength"
    integrationErrorMessage = "$context.integrationErrorMessage"
    sourceIp                = "$context.identity.sourceIp"
    userAgent               = "$context.identity.userAgent"
  })
}

resource "aws_apigatewayv2_api" "this" {
  name          = local.api_name
  description   = "Protected HTTP API used by Amazon Quick to submit OpenClaw-AWS jobs."
  protocol_type = "HTTP"

  disable_execute_api_endpoint = false

  tags = {
    Name = local.api_name
  }
}

resource "aws_apigatewayv2_integration" "job_receiver" {
  api_id = aws_apigatewayv2_api.this.id

  description            = "Lambda proxy integration for the OpenClaw-AWS job receiver."
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = var.job_receiver_invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = var.integration_timeout_milliseconds
}

resource "aws_apigatewayv2_authorizer" "quick_api_key" {
  api_id = aws_apigatewayv2_api.this.id

  name                              = local.authorizer_name
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = var.authorizer_invoke_arn
  authorizer_payload_format_version = "2.0"
  authorizer_result_ttl_in_seconds  = var.authorizer_result_ttl_seconds
  enable_simple_responses           = true
  identity_sources                  = ["$request.header.x-api-key"]
}

resource "aws_lambda_permission" "invoke_job_receiver" {
  statement_id  = "AllowOpenClawHttpApiInvokeJobReceiver"
  action        = "lambda:InvokeFunction"
  function_name = var.job_receiver_function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.this.execution_arn}/*/POST/jobs"
}

resource "aws_lambda_permission" "invoke_authorizer" {
  statement_id  = "AllowOpenClawHttpApiInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.quick_api_key.id}"
}

resource "aws_apigatewayv2_route" "jobs" {
  api_id = aws_apigatewayv2_api.this.id

  route_key          = local.route_key
  operation_name     = "SubmitOpenClawJob"
  target             = "integrations/${aws_apigatewayv2_integration.job_receiver.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.quick_api_key.id

  depends_on = [
    aws_lambda_permission.invoke_job_receiver,
    aws_lambda_permission.invoke_authorizer
  ]
}

resource "aws_apigatewayv2_stage" "default" {
  api_id = aws_apigatewayv2_api.this.id

  name        = local.stage_name
  description = "Auto-deployed default stage for the protected OpenClaw-AWS jobs API."
  auto_deploy = true

  access_log_settings {
    destination_arn = var.access_log_group_arn
    format          = local.access_log_format
  }

  default_route_settings {
    detailed_metrics_enabled = var.detailed_metrics_enabled
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
  }

  tags = {
    Name = "${local.api_name}-default-stage"
  }

  depends_on = [aws_apigatewayv2_route.jobs]
}


resource "aws_cloudwatch_metric_alarm" "api_gateway_5xx" {
  count = var.operational_alarms_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-api-gateway-5xx"
  alarm_description   = "OpenClaw HTTP API returned one or more 5xx responses."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = aws_apigatewayv2_api.this.id
    Stage = aws_apigatewayv2_stage.default.name
  }

  tags = {
    Name = "${var.name_prefix}-api-gateway-5xx"
  }
}
