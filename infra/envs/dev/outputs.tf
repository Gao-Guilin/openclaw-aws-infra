# OpenClaw-AWS dev environment outputs.
#
# Important first-stage infrastructure identifiers are exposed here.

output "aws_region" {
  description = "AWS Region used by the dev environment."
  value       = var.aws_region
}

output "name_prefix" {
  description = "Common resource name prefix."
  value       = local.name_prefix
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the OpenClaw-AWS VPC."
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the OpenClaw-AWS VPC."
  value       = module.network.vpc_cidr_block
}

output "internet_gateway_id" {
  description = "ID of the VPC Internet Gateway."
  value       = module.network.internet_gateway_id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets."
  value       = module.network.public_subnet_ids
}

output "public_subnet_availability_zones" {
  description = "Availability Zones used by the public subnets."
  value       = module.network.public_subnet_availability_zones
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = module.network.public_route_table_id
}

output "ecs_task_security_group_id" {
  description = "Security group ID reserved for ECS Fargate tasks."
  value       = module.network.ecs_task_security_group_id
}

output "efs_security_group_id" {
  description = "Security group ID used by EFS mount targets."
  value       = module.network.efs_security_group_id
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------

output "kms_key_id" {
  description = "ID of the project KMS key."
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "ARN of the project KMS key."
  value       = module.kms.key_arn
}

output "kms_alias_name" {
  description = "Alias of the project KMS key."
  value       = module.kms.alias_name
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------

output "secret_names" {
  description = "Map of Secrets Manager secret names."
  value       = module.secrets.secret_names
}

output "secret_arns" {
  description = "Map of Secrets Manager secret ARNs."
  value       = module.secrets.secret_arns
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

output "ecr_repository_name" {
  description = "Name of the OpenClaw Agent ECR repository."
  value       = module.ecr.repository_name
}

output "ecr_repository_arn" {
  description = "ARN of the OpenClaw Agent ECR repository."
  value       = module.ecr.repository_arn
}

output "ecr_repository_url" {
  description = "Repository URL used to tag, push, and pull the Agent image."
  value       = module.ecr.repository_url
}

# ---------------------------------------------------------------------------
# CloudWatch
# ---------------------------------------------------------------------------

output "cloudwatch_log_group_names" {
  description = "Map of CloudWatch log group names."
  value       = module.cloudwatch.log_group_names
}

output "cloudwatch_log_group_arns" {
  description = "Map of CloudWatch log group ARNs."
  value       = module.cloudwatch.log_group_arns
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------

output "s3_bucket_name" {
  description = "Name of the reports and archive S3 bucket."
  value       = module.s3.bucket_name
}

output "s3_bucket_arn" {
  description = "ARN of the reports and archive S3 bucket."
  value       = module.s3.bucket_arn
}

output "s3_reports_prefix" {
  description = "S3 prefix used for generated reports."
  value       = module.s3.reports_prefix
}

output "s3_archive_prefix" {
  description = "S3 prefix used for archived data."
  value       = module.s3.archive_prefix
}

output "s3_evidence_prefix" {
  description = "S3 prefix used for deployment and test evidence."
  value       = module.s3.evidence_prefix
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------

output "dynamodb_table_names" {
  description = "Map of DynamoDB table names."
  value       = module.dynamodb.table_names
}

output "dynamodb_table_arns" {
  description = "Map of DynamoDB table ARNs."
  value       = module.dynamodb.table_arns
}

# ---------------------------------------------------------------------------
# SNS
# ---------------------------------------------------------------------------

output "sns_topic_name" {
  description = "Name of the project notification SNS topic."
  value       = module.sns.topic_name
}

output "sns_topic_arn" {
  description = "ARN of the project notification SNS topic."
  value       = module.sns.topic_arn
}

# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------

output "sqs_queue_names" {
  description = "Map of high, medium, and low priority queue names."
  value       = module.sqs.queue_names
}

output "sqs_queue_urls" {
  description = "Map of high, medium, and low priority queue URLs."
  value       = module.sqs.queue_urls
}

output "sqs_queue_arns" {
  description = "Map of high, medium, and low priority queue ARNs."
  value       = module.sqs.queue_arns
}

output "sqs_dlq_names" {
  description = "Map of dead-letter queue names."
  value       = module.sqs.dlq_names
}

output "sqs_dlq_urls" {
  description = "Map of dead-letter queue URLs."
  value       = module.sqs.dlq_urls
}

output "sqs_dlq_arns" {
  description = "Map of dead-letter queue ARNs."
  value       = module.sqs.dlq_arns
}

# ---------------------------------------------------------------------------
# EFS
# ---------------------------------------------------------------------------

output "efs_file_system_id" {
  description = "ID of the temporary Demo EFS file system."
  value       = module.efs.file_system_id
}

output "efs_file_system_arn" {
  description = "ARN of the temporary Demo EFS file system."
  value       = module.efs.file_system_arn
}

output "efs_access_point_id" {
  description = "ID of the EFS runtime access point."
  value       = module.efs.access_point_id
}

output "efs_access_point_arn" {
  description = "ARN of the EFS runtime access point."
  value       = module.efs.access_point_arn
}

output "efs_mount_target_ids" {
  description = "Map of subnet IDs to EFS mount target IDs."
  value       = module.efs.mount_target_ids
}

# ---------------------------------------------------------------------------
# AWS Budgets
# ---------------------------------------------------------------------------

output "budget_name" {
  description = "Name of the monthly AWS cost budget."
  value       = module.budgets.budget_name
}

output "budget_arn" {
  description = "ARN of the monthly AWS cost budget."
  value       = module.budgets.budget_arn
}

output "monthly_budget_limit_usd" {
  description = "Configured monthly AWS cost budget limit."
  value       = module.budgets.monthly_budget_limit_usd
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role."
  value       = module.iam.ecs_task_execution_role_arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task runtime role."
  value       = module.iam.ecs_task_role_arn
}

output "lambda_job_receiver_role_arn" {
  description = "ARN of the Lambda job receiver role."
  value       = module.iam.lambda_job_receiver_role_arn
}

output "step_functions_role_arn" {
  description = "ARN of the Step Functions execution role."
  value       = module.iam.step_functions_role_arn
}

output "eventbridge_scheduler_role_arn" {
  description = "ARN of the EventBridge Scheduler execution role."
  value       = module.iam.eventbridge_scheduler_role_arn
}

# ---------------------------------------------------------------------------
# ECS
# ---------------------------------------------------------------------------

output "agent_image_uri" {
  description = "Digest-pinned ECR image URI used by the ECS task definition."
  value       = "${module.ecr.repository_url}@${var.agent_image_digest}"
}

output "ecs_cluster_name" {
  description = "Name of the OpenClaw ECS cluster."
  value       = module.ecs.cluster_name
}

output "ecs_cluster_arn" {
  description = "ARN of the OpenClaw ECS cluster."
  value       = module.ecs.cluster_arn
}

output "ecs_task_definition_family" {
  description = "Family name of the OpenClaw Agent task definition."
  value       = module.ecs.task_definition_family
}

output "ecs_task_definition_arn" {
  description = "ARN of the active OpenClaw Agent task definition revision."
  value       = module.ecs.task_definition_arn
}

output "ecs_container_name" {
  description = "Container name used by EventBridge Pipes task overrides."
  value       = module.ecs.container_name
}

output "ecs_task_cpu" {
  description = "Configured ECS Fargate task CPU units."
  value       = module.ecs.task_cpu
}

output "ecs_task_memory" {
  description = "Configured ECS Fargate task memory in MiB."
  value       = module.ecs.task_memory
}

# ---------------------------------------------------------------------------
# Step Functions
# ---------------------------------------------------------------------------

output "step_functions_state_machine_name" {
  description = "Name of the OpenClaw workflow state machine."
  value       = module.stepfunctions.state_machine_name
}

output "step_functions_state_machine_arn" {
  description = "ARN of the OpenClaw workflow state machine."
  value       = module.stepfunctions.state_machine_arn
}

output "step_functions_supported_task_types" {
  description = "Task types accepted by the first workflow version."
  value       = module.stepfunctions.supported_task_types
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------

output "lambda_job_receiver_function_name" {
  description = "Name of the Lambda job receiver function."
  value       = module.lambda.job_receiver_function_name
}

output "lambda_job_receiver_function_arn" {
  description = "ARN of the Lambda job receiver function."
  value       = module.lambda.job_receiver_function_arn
}

output "lambda_authorizer_function_name" {
  description = "Name of the Lambda API authorizer function."
  value       = module.lambda.authorizer_function_name
}

output "lambda_authorizer_function_arn" {
  description = "ARN of the Lambda API authorizer function."
  value       = module.lambda.authorizer_function_arn
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------

output "api_gateway_id" {
  description = "ID of the protected OpenClaw HTTP API."
  value       = module.api_gateway.api_id
}

output "api_gateway_endpoint" {
  description = "Base HTTPS endpoint of the protected OpenClaw HTTP API."
  value       = module.api_gateway.api_endpoint
}

output "api_gateway_jobs_endpoint" {
  description = "Protected POST endpoint used by Amazon Quick to submit jobs."
  value       = module.api_gateway.jobs_endpoint
}

output "api_gateway_route_key" {
  description = "Route key exposed by the protected OpenClaw HTTP API."
  value       = module.api_gateway.route_key
}

output "api_gateway_authorizer_name" {
  description = "Name of the Lambda request authorizer."
  value       = module.api_gateway.authorizer_name
}

# ---------------------------------------------------------------------------
# EventBridge Pipes and Scheduler
# ---------------------------------------------------------------------------

output "eventbridge_pipe_names" {
  description = "Map of priority labels to EventBridge Pipe names."
  value       = module.eventbridge.pipe_names
}

output "eventbridge_pipe_arns" {
  description = "Map of priority labels to EventBridge Pipe ARNs."
  value       = module.eventbridge.pipe_arns
}

output "eventbridge_pipe_desired_states" {
  description = "Desired state of each EventBridge Pipe."
  value       = module.eventbridge.pipe_desired_states
}

output "eventbridge_schedule_names" {
  description = "Map of schedule keys to EventBridge Scheduler names."
  value       = module.eventbridge.schedule_names
}

output "eventbridge_schedule_arns" {
  description = "Map of schedule keys to EventBridge Scheduler ARNs."
  value       = module.eventbridge.schedule_arns
}

output "eventbridge_schedule_states" {
  description = "State of each EventBridge Scheduler schedule."
  value       = module.eventbridge.schedule_states
}

output "eventbridge_schedule_expressions" {
  description = "Cron expression used by each EventBridge Scheduler schedule."
  value       = module.eventbridge.schedule_expressions
}

output "eventbridge_schedule_timezone" {
  description = "Timezone used to evaluate EventBridge Scheduler cron expressions."
  value       = module.eventbridge.schedule_timezone
}

# ---------------------------------------------------------------------------
# Additional IAM roles
# ---------------------------------------------------------------------------

output "lambda_authorizer_role_arn" {
  description = "ARN of the Lambda authorizer runtime role."
  value       = module.iam.lambda_authorizer_role_arn
}

output "eventbridge_pipes_role_arn" {
  description = "ARN of the EventBridge Pipes execution role."
  value       = module.iam.eventbridge_pipes_role_arn
}

# ---------------------------------------------------------------------------
# GitHub Actions basic CD
# ---------------------------------------------------------------------------

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = module.github_oidc.oidc_provider_arn
}

output "github_actions_cd_role_name" {
  description = "Name of the GitHub Actions basic CD role."
  value       = module.github_oidc.cd_role_name
}

output "github_actions_cd_role_arn" {
  description = "ARN of the GitHub Actions basic CD role."
  value       = module.github_oidc.cd_role_arn
}

output "github_actions_cd_policy_arn" {
  description = "ARN of the GitHub Actions basic CD policy."
  value       = module.github_oidc.cd_policy_arn
}

output "github_actions_cd_allowed_subjects" {
  description = "GitHub OIDC subject patterns trusted by the basic CD role."
  value       = module.github_oidc.allowed_subjects
}

output "cloudwatch_alarm_names" {
  description = "Project CloudWatch alarms routed into alert analysis."
  value = {
    job_receiver_errors = module.lambda.job_receiver_error_alarm_name
    api_gateway_5xx     = module.api_gateway.api_gateway_5xx_alarm_name
  }
}

output "cloudwatch_alarm_arns" {
  description = "ARNs of project CloudWatch alarms."
  value = {
    job_receiver_errors = module.lambda.job_receiver_error_alarm_arn
    api_gateway_5xx     = module.api_gateway.api_gateway_5xx_alarm_arn
  }
}

output "cloudwatch_alarm_event_rule_name" {
  description = "EventBridge rule that routes CloudWatch ALARM state changes."
  value       = module.eventbridge.cloudwatch_alarm_rule_name
}

output "cloudwatch_alarm_event_rule_arn" {
  description = "ARN of the EventBridge CloudWatch alarm rule."
  value       = module.eventbridge.cloudwatch_alarm_rule_arn
}

output "alert_ingress_enabled" {
  description = "Whether CloudWatch alarm ingress is enabled."
  value       = module.eventbridge.alert_ingress_enabled
}
