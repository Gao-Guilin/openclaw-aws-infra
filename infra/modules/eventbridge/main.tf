locals {
  pipe_priorities = toset(["high", "medium", "low"])

  schedules = {
    morning_inspection = {
      name                = "${var.name_prefix}-morning-inspection"
      description         = "Runs the OpenClaw daily inspection dispatcher every day at 09:00 Asia/Shanghai."
      schedule_expression = var.morning_schedule_expression
      task_type           = "daily_inspection"
      priority            = "medium"
    }

    afternoon_inspection = {
      name                = "${var.name_prefix}-afternoon-inspection"
      description         = "Runs the OpenClaw daily inspection dispatcher every day at 16:00 Asia/Shanghai."
      schedule_expression = var.afternoon_schedule_expression
      task_type           = "daily_inspection"
      priority            = "medium"
    }

    weekly_report = {
      name                = "${var.name_prefix}-weekly-report"
      description         = "Runs the OpenClaw weekly report dispatcher on the configured weekly schedule."
      schedule_expression = var.weekly_report_schedule_expression
      task_type           = "report_generation"
      priority            = "low"
    }
  }
}

resource "aws_pipes_pipe" "priority" {
  for_each = local.pipe_priorities

  name          = "${var.name_prefix}-${each.key}-priority-pipe"
  description   = "Consumes the ${each.key}-priority SQS queue and starts one OpenClaw ECS Fargate task."
  role_arn      = var.pipes_role_arn
  source        = var.sqs_queue_arns[each.key]
  target        = var.ecs_cluster_arn
  desired_state = var.pipes_enabled ? "RUNNING" : "STOPPED"

  source_parameters {
    sqs_queue_parameters {
      batch_size = 1
    }
  }

  target_parameters {
    ecs_task_parameters {
      task_definition_arn     = var.ecs_task_definition_arn
      task_count              = 1
      launch_type             = "FARGATE"
      platform_version        = var.fargate_platform_version
      enable_ecs_managed_tags = true
      propagate_tags          = "TASK_DEFINITION"

      network_configuration {
        aws_vpc_configuration {
          subnets          = var.subnet_ids
          security_groups  = var.security_group_ids
          assign_public_ip = var.assign_public_ip ? "ENABLED" : "DISABLED"
        }
      }

      overrides {
        container_override {
          name   = var.ecs_container_name
          cpu    = var.task_cpu
          memory = var.task_memory

          environment {
            name  = "OPENCLAW_JOB_ID"
            value = "$.body.job_id"
          }
          environment {
            name  = "OPENCLAW_TASK_TYPE"
            value = "$.body.task_type"
          }
          environment {
            name  = "OPENCLAW_TARGET"
            value = "$.body.target"
          }
          environment {
            name  = "OPENCLAW_PRIORITY"
            value = each.key
          }
          environment {
            name  = "OPENCLAW_SOURCE"
            value = "$.body.source"
          }
          environment {
            name  = "OPENCLAW_REQUESTED_AT"
            value = "$.body.requested_at"
          }
          environment {
            name  = "OPENCLAW_ALERT_JSON"
            value = "$.body.alert_json"
          }
        }
      }
    }
  }

  log_configuration {
    level = var.pipe_log_level

    cloudwatch_logs_log_destination {
      log_group_arn = var.pipes_log_group_arn
    }
  }

  tags = {
    Name     = "${var.name_prefix}-${each.key}-priority-pipe"
    Priority = each.key
  }
}

# Scheduler invokes the same dispatcher Lambda as API and alarm ingress.  This
# creates the Jobs record before the workflow starts and closes the lifecycle
# observability gap that existed when Scheduler targeted Step Functions directly.
resource "aws_scheduler_schedule" "workflow" {
  for_each = local.schedules

  name        = each.value.name
  group_name  = "default"
  description = each.value.description
  state       = var.scheduler_enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.job_receiver_function_arn
    role_arn = var.scheduler_role_arn

    input = replace(
      replace(
        jsonencode({
          event_type     = "scheduled-job"
          execution_id   = "<aws.scheduler.execution-id>"
          schedule_name  = each.value.name
          scheduled_time = "<aws.scheduler.scheduled-time>"
          task_type      = each.value.task_type
          priority       = each.value.priority
          target         = "aws-account"
          source         = "scheduler"
        }),
        "\\u003c",
        "<"
      ),
      "\\u003e",
      ">"
    )

    retry_policy {
      maximum_event_age_in_seconds = var.scheduler_maximum_event_age_seconds
      maximum_retry_attempts       = var.scheduler_maximum_retry_attempts
    }
  }
}

# Full Alert path: CloudWatch alarm ALARM state -> EventBridge -> dispatcher
# Lambda -> Jobs -> Step Functions -> SQS -> Pipes -> ECS alert skill.
resource "aws_cloudwatch_event_rule" "cloudwatch_alarm" {
  name        = "${var.name_prefix}-cloudwatch-alarm-state-change"
  description = "Routes project CloudWatch ALARM state changes into OpenClaw alert analysis."
  state       = var.alert_ingress_enabled ? "ENABLED" : "DISABLED"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = var.alarm_name_prefix }]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = {
    Name = "${var.name_prefix}-cloudwatch-alarm-state-change"
  }
}

resource "aws_cloudwatch_event_target" "cloudwatch_alarm" {
  rule = aws_cloudwatch_event_rule.cloudwatch_alarm.name
  arn  = var.job_receiver_function_arn

  retry_policy {
    maximum_event_age_in_seconds = var.alert_maximum_event_age_seconds
    maximum_retry_attempts       = var.alert_maximum_retry_attempts
  }
}

resource "aws_lambda_permission" "allow_eventbridge_alarm" {
  statement_id  = "AllowEventBridgeCloudWatchAlarm"
  action        = "lambda:InvokeFunction"
  function_name = var.job_receiver_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cloudwatch_alarm.arn
}
