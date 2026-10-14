locals {
  cluster_name           = "${var.name_prefix}-cluster"
  task_definition_family = "${var.name_prefix}-agent"
  container_name         = "${var.name_prefix}-agent"
  runtime_volume_name    = "openclaw-runtime"

  core_environment_variables = {
    AWS_REGION                          = var.aws_region
    OPENCLAW_ENVIRONMENT                = var.environment
    AWS_DEFAULT_REGION                  = var.aws_region
    OPENCLAW_RUNTIME_DIR                = var.runtime_mount_path
    OPENCLAW_WORKSPACE                  = "${var.runtime_mount_path}/workspace"
    OPENCLAW_TASK_TYPE                  = "healthcheck"
    OPENCLAW_JOB_ID                     = "manual-test"
    OPENCLAW_TARGET                     = "aws-account"
    OPENCLAW_PRIORITY                   = "medium"
    DYNAMODB_JOBS_TABLE                 = var.dynamodb_jobs_table_name
    DYNAMODB_ALERTS_TABLE               = var.dynamodb_alerts_table_name
    DYNAMODB_REPORTS_TABLE              = var.dynamodb_reports_table_name
    S3_REPORT_BUCKET                    = var.s3_report_bucket_name
    SNS_TOPIC_ARN                       = var.sns_topic_arn
    OPENCLAW_SNS_NOTIFY_ENABLED         = tostring(var.sns_notifications_enabled)
    OPENCLAW_SNS_NOTIFY_STRICT          = tostring(var.sns_notifications_strict)
    OPENCLAW_ALERT_REQUIRE_PAYLOAD      = tostring(var.alert_require_payload)
    OPENCLAW_ALERT_PERSIST_DYNAMODB     = tostring(var.alert_persist_dynamodb)
    OPENCLAW_EFS_HISTORY_ENABLED        = tostring(var.efs_history_enabled)
    OPENCLAW_EFS_HISTORY_STRICT         = tostring(var.efs_history_strict)
    OPENCLAW_EFS_HISTORY_DIR            = "${var.runtime_mount_path}/history"
    OPENCLAW_EFS_HISTORY_TASK_TYPES     = join(",", sort(tolist(var.efs_history_task_types)))
    OPENCLAW_EFS_HISTORY_RETENTION_DAYS = tostring(var.efs_history_retention_days)
    OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES = tostring(var.efs_history_max_file_bytes)
    OPENCLAW_REPORT_EFS_AGGREGATE       = tostring(var.report_efs_aggregate_enabled)
    OPENCLAW_REPORT_EFS_LOOKBACK_HOURS  = tostring(var.report_efs_lookback_hours)
    OPENCLAW_REPORT_EFS_MAX_ITEMS       = tostring(var.report_efs_max_items)
    QQBOT_ENABLED                       = tostring(var.qqbot_enabled)
    QQBOT_NAME                          = var.qqbot_name
  }

  container_environment_variables = merge(
    local.core_environment_variables,
    var.additional_environment_variables
  )

  base_container_secrets = [
    {
      name      = "DEEPSEEK_API_KEY"
      valueFrom = "${var.deepseek_api_key_secret_arn}:DEEPSEEK_API_KEY::"
    },
    {
      name      = "OPENCLAW_GATEWAY_TOKEN"
      valueFrom = "${var.openclaw_gateway_token_secret_arn}:OPENCLAW_GATEWAY_TOKEN::"
    }
  ]

  qqbot_container_secrets = var.qqbot_enabled ? [
    {
      name      = "QQBOT_APP_ID"
      valueFrom = "${var.qqbot_app_id_secret_arn}:QQBOT_APP_ID::"
    },
    {
      name      = "QQBOT_CLIENT_SECRET"
      valueFrom = "${var.qqbot_client_secret_arn}:QQBOT_CLIENT_SECRET::"
    }
  ] : []

  container_secrets = concat(
    local.base_container_secrets,
    local.qqbot_container_secrets
  )
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = var.container_insights_enabled ? "enabled" : "disabled"
  }

  tags = {
    Name = local.cluster_name
  }
}

resource "aws_ecs_task_definition" "agent" {
  family                   = local.task_definition_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn
  skip_destroy             = true

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = local.runtime_volume_name

    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/"
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true
      cpu       = var.task_cpu
      memory    = var.task_memory

      environment = [
        for key in sort(keys(local.container_environment_variables)) : {
          name  = key
          value = local.container_environment_variables[key]
        }
      ]

      secrets = local.container_secrets

      mountPoints = [
        {
          sourceVolume  = local.runtime_volume_name
          containerPath = var.runtime_mount_path
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.cloudwatch_log_group_name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }

      linuxParameters = {
        initProcessEnabled = true
      }

      stopTimeout = 120
    }
  ])

  tags = {
    Name = local.task_definition_family
  }
}
