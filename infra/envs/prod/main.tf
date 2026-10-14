# OpenClaw-AWS prod environment root module.
#
# Child modules are composed here to build the first-stage AWS foundation.

module "network" {
  source = "../../modules/network"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
}

module "kms" {
  source = "../../modules/kms"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
}

module "secrets" {
  source = "../../modules/secrets"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.key_arn
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.key_arn
}

module "cloudwatch" {
  source = "../../modules/cloudwatch"

  name_prefix        = local.name_prefix
  kms_key_arn        = module.kms.key_arn
  log_retention_days = var.cloudwatch_log_retention_days
}

module "s3" {
  source = "../../modules/s3"

  name_prefix                     = local.name_prefix
  aws_region                      = var.aws_region
  kms_key_arn                     = module.kms.key_arn
  current_version_expiration_days = var.s3_current_object_expiration_days
  force_destroy                   = var.s3_force_destroy
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  name_prefix                 = local.name_prefix
  kms_key_arn                 = module.kms.key_arn
  deletion_protection_enabled = var.dynamodb_deletion_protection_enabled
}

module "sns" {
  source = "../../modules/sns"

  name_prefix         = local.name_prefix
  aws_region          = var.aws_region
  kms_key_arn         = module.kms.key_arn
  email_subscriptions = var.sns_email_subscriptions
}

module "sqs" {
  source = "../../modules/sqs"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.key_arn
}

module "efs" {
  source = "../../modules/efs"

  name_prefix       = local.name_prefix
  kms_key_arn       = module.kms.key_arn
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.efs_security_group_id
}

module "budgets" {
  source = "../../modules/budgets"

  name_prefix              = local.name_prefix
  sns_topic_arn            = module.sns.topic_arn
  monthly_budget_limit_usd = var.monthly_budget_limit_usd

  depends_on = [
    module.sns
  ]
}

module "iam" {
  source = "../../modules/iam"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  kms_key_arn = module.kms.key_arn

  ecr_repository_arn             = module.ecr.repository_arn
  additional_ecr_repository_arns = var.additional_ecr_pull_repository_arns
  quick_api_key_secret_arn       = module.secrets.quick_api_key_secret_arn
  # Keep the ECS task execution role limited to the four container runtime
  # secrets. The Quick API key is reserved for the Lambda authorizer.
  secret_arns = {
    deepseek_api_key       = module.secrets.deepseek_api_key_secret_arn
    openclaw_gateway_token = module.secrets.openclaw_gateway_token_secret_arn
    qqbot_app_id           = module.secrets.qqbot_app_id_secret_arn
    qqbot_client_secret    = module.secrets.qqbot_client_secret_arn
  }
  cloudwatch_log_group_arns = module.cloudwatch.log_group_arns
  s3_bucket_arn             = module.s3.bucket_arn
  dynamodb_table_arns       = module.dynamodb.table_arns
  sns_topic_arn             = module.sns.topic_arn
  sqs_queue_arns            = module.sqs.queue_arns
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  name_prefix                    = local.name_prefix
  project_resource_prefix        = var.project_name
  aws_region                     = var.aws_region
  environment_name               = var.environment
  github_repository              = var.github_repository
  github_branch_patterns         = var.github_cd_branch_patterns
  github_environment_names       = var.github_environment_names
  ecr_repository_arn             = module.ecr.repository_arn
  additional_ecr_repository_arns = var.additional_cd_ecr_repository_arns
  oidc_provider_arn              = var.github_oidc_provider_arn
  terraform_deploy_enabled       = true
  terraform_state_bucket         = var.terraform_state_bucket
  terraform_state_key            = var.terraform_state_key
}

# ---------------------------------------------------------------------------
# Second-stage runtime and orchestration
# ---------------------------------------------------------------------------

module "ecs" {
  source = "../../modules/ecs"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  environment = var.environment

  container_image         = local.agent_image_uri
  task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn           = module.iam.ecs_task_role_arn

  cloudwatch_log_group_name = module.cloudwatch.ecs_agent_log_group_name

  efs_file_system_id  = module.efs.file_system_id
  efs_access_point_id = module.efs.access_point_id

  deepseek_api_key_secret_arn       = module.secrets.deepseek_api_key_secret_arn
  openclaw_gateway_token_secret_arn = module.secrets.openclaw_gateway_token_secret_arn
  qqbot_app_id_secret_arn           = module.secrets.qqbot_app_id_secret_arn
  qqbot_client_secret_arn           = module.secrets.qqbot_client_secret_arn

  dynamodb_jobs_table_name    = module.dynamodb.jobs_table_name
  dynamodb_alerts_table_name  = module.dynamodb.alerts_table_name
  dynamodb_reports_table_name = module.dynamodb.reports_table_name
  s3_report_bucket_name       = module.s3.bucket_name
  sns_topic_arn               = module.sns.topic_arn
  alert_require_payload       = true
  alert_persist_dynamodb      = var.alert_persist_dynamodb

  task_cpu      = var.ecs_task_cpu
  task_memory   = var.ecs_task_memory
  qqbot_enabled = var.qqbot_enabled

  efs_history_enabled          = var.efs_history_enabled
  efs_history_strict           = var.efs_history_strict
  efs_history_task_types       = var.efs_history_task_types
  efs_history_retention_days   = var.efs_history_retention_days
  efs_history_max_file_bytes   = var.efs_history_max_file_bytes
  report_efs_aggregate_enabled = var.report_efs_aggregate_enabled
  report_efs_lookback_hours    = var.report_efs_lookback_hours
  report_efs_max_items         = var.report_efs_max_items

  depends_on = [
    module.iam,
    module.cloudwatch,
    module.efs
  ]
}

module "stepfunctions" {
  source = "../../modules/stepfunctions"

  name_prefix              = local.name_prefix
  role_arn                 = module.iam.step_functions_role_arn
  cloudwatch_log_group_arn = module.cloudwatch.step_functions_log_group_arn
  sqs_queue_urls           = module.sqs.queue_urls

  depends_on = [
    module.iam,
    module.cloudwatch,
    module.sqs
  ]
}

module "lambda" {
  source = "../../modules/lambda"

  name_prefix = local.name_prefix
  environment = var.environment

  job_receiver_role_arn = module.iam.lambda_job_receiver_role_arn
  authorizer_role_arn   = module.iam.lambda_authorizer_role_arn

  job_receiver_log_group_name = module.cloudwatch.lambda_job_receiver_log_group_name
  authorizer_log_group_name   = module.cloudwatch.lambda_authorizer_log_group_name

  jobs_table_name          = module.dynamodb.jobs_table_name
  state_machine_arn        = module.stepfunctions.state_machine_arn
  quick_api_key_secret_arn = module.secrets.quick_api_key_secret_arn

  operational_alarms_enabled = var.operational_alarms_enabled
  alarm_period_seconds       = var.alarm_period_seconds
}

module "api_gateway" {
  source = "../../modules/api-gateway"

  name_prefix = local.name_prefix

  job_receiver_invoke_arn    = module.lambda.job_receiver_invoke_arn
  job_receiver_function_name = module.lambda.job_receiver_function_name
  authorizer_invoke_arn      = module.lambda.authorizer_invoke_arn
  authorizer_function_name   = module.lambda.authorizer_function_name
  access_log_group_arn       = module.cloudwatch.api_gateway_log_group_arn

  operational_alarms_enabled = var.operational_alarms_enabled
  alarm_period_seconds       = var.alarm_period_seconds

  depends_on = [
    module.lambda,
    module.cloudwatch
  ]
}


module "eventbridge" {
  source = "../../modules/eventbridge"

  name_prefix = local.name_prefix

  pipes_role_arn     = module.iam.eventbridge_pipes_role_arn
  scheduler_role_arn = module.iam.eventbridge_scheduler_role_arn

  sqs_queue_arns = module.sqs.queue_arns

  ecs_cluster_arn         = module.ecs.cluster_arn
  ecs_task_definition_arn = module.ecs.task_definition_arn
  ecs_container_name      = module.ecs.container_name
  task_cpu                = var.ecs_task_cpu
  task_memory             = var.ecs_task_memory

  subnet_ids         = module.network.public_subnet_ids
  security_group_ids = [module.network.ecs_task_security_group_id]
  assign_public_ip   = true

  pipes_log_group_arn = module.cloudwatch.eventbridge_pipes_log_group_arn
  pipes_enabled       = var.eventbridge_pipes_enabled

  job_receiver_function_arn         = module.lambda.job_receiver_function_arn
  job_receiver_function_name        = module.lambda.job_receiver_function_name
  scheduler_enabled                 = var.eventbridge_scheduler_enabled
  schedule_timezone                 = var.scheduler_timezone
  morning_schedule_expression       = var.morning_schedule_expression
  afternoon_schedule_expression     = var.afternoon_schedule_expression
  weekly_report_schedule_expression = var.weekly_report_schedule_expression
  alert_ingress_enabled             = var.alert_ingress_enabled
  alarm_name_prefix                 = local.name_prefix

  depends_on = [
    module.iam,
    module.ecs,
    module.stepfunctions,
    module.lambda,
    module.cloudwatch,
    module.api_gateway
  ]
}
