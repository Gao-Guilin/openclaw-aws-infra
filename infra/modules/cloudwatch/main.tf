locals {
  log_groups = {
    ecs_agent = {
      name = "/${var.name_prefix}/ecs/agent"
    }

    lambda_job_receiver = {
      name = "/aws/lambda/${var.name_prefix}-job-receiver"
    }

    lambda_authorizer = {
      name = "/aws/lambda/${var.name_prefix}-api-authorizer"
    }

    step_functions = {
      name = "/aws/vendedlogs/states/${var.name_prefix}-workflow"
    }

    api_gateway = {
      name = "/aws/apigateway/${var.name_prefix}-access"
    }

    eventbridge_pipes = {
      name = "/aws/vendedlogs/pipes/${var.name_prefix}-task-dispatch"
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups

  name              = each.value.name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = each.value.name
  }
}
