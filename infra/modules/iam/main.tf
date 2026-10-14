data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  ecs_log_group_arn               = var.cloudwatch_log_group_arns["ecs_agent"]
  lambda_log_group_arn            = var.cloudwatch_log_group_arns["lambda_job_receiver"]
  lambda_authorizer_log_group_arn = var.cloudwatch_log_group_arns["lambda_authorizer"]
  eventbridge_pipes_log_group_arn = var.cloudwatch_log_group_arns["eventbridge_pipes"]

  state_machine_arn         = "arn:${data.aws_partition.current.partition}:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.name_prefix}-workflow"
  ecs_cluster_arn           = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.name_prefix}-cluster"
  job_receiver_function_arn = "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-job-receiver"

  ecs_task_definition_arn = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.name_prefix}-agent:*"

  all_log_resource_arns = flatten([
    for arn in values(var.cloudwatch_log_group_arns) :
    [arn, "${arn}:*"]
  ])

  kms_via_services = [
    "dynamodb.${var.aws_region}.amazonaws.com",
    "s3.${var.aws_region}.amazonaws.com",
    "sqs.${var.aws_region}.amazonaws.com",
    "sns.${var.aws_region}.amazonaws.com"
  ]
}

# ---------------------------------------------------------------------------
# Trust policies
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "step_functions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pipes_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# IAM roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ecs_task_execution" {
  name                 = "${var.name_prefix}-ecs-task-execution-role"
  description          = "Allows ECS Fargate to pull images, write logs, and retrieve secrets."
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-ecs-task-execution-role"
  }
}

resource "aws_iam_role" "ecs_task" {
  name                 = "${var.name_prefix}-ecs-task-role"
  description          = "Runtime permissions used by the OpenClaw Agent container."
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-ecs-task-role"
  }
}

resource "aws_iam_role" "lambda_job_receiver" {
  name                 = "${var.name_prefix}-lambda-job-receiver-role"
  description          = "Runtime role used by the OpenClaw job receiver Lambda."
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-lambda-job-receiver-role"
  }
}

resource "aws_iam_role" "lambda_authorizer" {
  name                 = "${var.name_prefix}-lambda-authorizer-role"
  description          = "Runtime role used by the API Gateway Lambda authorizer."
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-lambda-authorizer-role"
  }
}

resource "aws_iam_role" "step_functions" {
  name                 = "${var.name_prefix}-step-functions-role"
  description          = "Execution role used by the OpenClaw Step Functions workflow."
  assume_role_policy   = data.aws_iam_policy_document.step_functions_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-step-functions-role"
  }
}

resource "aws_iam_role" "eventbridge_scheduler" {
  name                 = "${var.name_prefix}-eventbridge-scheduler-role"
  description          = "Execution role used by EventBridge Scheduler."
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-eventbridge-scheduler-role"
  }
}

resource "aws_iam_role" "eventbridge_pipes" {
  name                 = "${var.name_prefix}-eventbridge-pipes-role"
  description          = "Execution role used by EventBridge Pipes to consume SQS messages and run ECS tasks."
  assume_role_policy   = data.aws_iam_policy_document.pipes_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-eventbridge-pipes-role"
  }
}

# ---------------------------------------------------------------------------
# ECS Task Execution Role policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_execution" {
  statement {
    sid       = "ECRAuthorization"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullAgentImage"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]

    resources = concat([var.ecr_repository_arn], var.additional_ecr_repository_arns)
  }

  statement {
    sid    = "WriteECSLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${local.ecs_log_group_arn}:*"
    ]
  }

  statement {
    sid     = "ReadContainerSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]

    resources = values(var.secret_arns)
  }

  statement {
    sid       = "DecryptContainerSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "secretsmanager.${var.aws_region}.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_policy" "ecs_task_execution" {
  name        = "${var.name_prefix}-ecs-task-execution-policy"
  description = "Least-privilege permissions used when ECS starts the OpenClaw task."
  policy      = data.aws_iam_policy_document.ecs_task_execution.json

  tags = {
    Name = "${var.name_prefix}-ecs-task-execution-policy"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_task_execution.arn
}

# ---------------------------------------------------------------------------
# ECS Task Role policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_task" {
  statement {
    sid       = "ReadCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadCloudWatchState"
    effect = "Allow"

    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms"
    ]

    resources = ["*"]
  }

  statement {
    sid       = "ListLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadProjectLogs"
    effect = "Allow"

    actions = [
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents"
    ]

    resources = local.all_log_resource_arns
  }

  statement {
    sid    = "InspectAWSResources"
    effect = "Allow"

    actions = [
      "ecs:DescribeClusters",
      "elasticfilesystem:DescribeFileSystems",
      "ec2:DescribeNatGateways",
      "budgets:ViewBudget",
      "ce:GetCostAndUsage"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadAndWriteProjectTables"
    effect = "Allow"

    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem"
    ]

    resources = values(var.dynamodb_table_arns)
  }

  statement {
    sid    = "ReadReportBucket"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]

    resources = [var.s3_bucket_arn]
  }

  statement {
    sid    = "ReadAndWriteReports"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]

    resources = [
      "${var.s3_bucket_arn}/reports/*",
      "${var.s3_bucket_arn}/archive/*"
    ]
  }

  statement {
    sid    = "ConsumePriorityQueues"
    effect = "Allow"

    actions = [
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility"
    ]

    resources = values(var.sqs_queue_arns)
  }

  statement {
    sid    = "PublishNotifications"
    effect = "Allow"

    actions = [
      "sns:GetTopicAttributes",
      "sns:Publish"
    ]

    resources = [var.sns_topic_arn]
  }

  statement {
    sid    = "UseProjectEncryptionKey"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = local.kms_via_services
    }
  }
}

resource "aws_iam_policy" "ecs_task" {
  name        = "${var.name_prefix}-ecs-task-policy"
  description = "Runtime AWS permissions used by the OpenClaw Agent."
  policy      = data.aws_iam_policy_document.ecs_task.json

  tags = {
    Name = "${var.name_prefix}-ecs-task-policy"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task.arn
}

# ---------------------------------------------------------------------------
# Lambda job receiver policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_job_receiver" {
  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${local.lambda_log_group_arn}:*"
    ]
  }

  statement {
    sid    = "ManageJobRecords"
    effect = "Allow"

    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem"
    ]

    resources = [
      var.dynamodb_table_arns["jobs"]
    ]
  }

  statement {
    sid       = "DecryptJobsTableKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "dynamodb.${var.aws_region}.amazonaws.com"
      ]
    }
  }

  statement {
    sid       = "StartOpenClawWorkflow"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [local.state_machine_arn]
  }
}

resource "aws_iam_policy" "lambda_job_receiver" {
  name        = "${var.name_prefix}-lambda-job-receiver-policy"
  description = "Initial permissions used by the job receiver Lambda."
  policy      = data.aws_iam_policy_document.lambda_job_receiver.json

  tags = {
    Name = "${var.name_prefix}-lambda-job-receiver-policy"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_job_receiver" {
  role       = aws_iam_role.lambda_job_receiver.name
  policy_arn = aws_iam_policy.lambda_job_receiver.arn
}

# ---------------------------------------------------------------------------
# Lambda authorizer policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_authorizer" {
  statement {
    sid    = "WriteLambdaAuthorizerLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${local.lambda_authorizer_log_group_arn}:*"
    ]
  }

  statement {
    sid       = "ReadQuickAPIKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.quick_api_key_secret_arn]
  }

  statement {
    sid       = "DecryptQuickAPIKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "secretsmanager.${var.aws_region}.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_policy" "lambda_authorizer" {
  name        = "${var.name_prefix}-lambda-authorizer-policy"
  description = "Least-privilege permissions used by the API Gateway Lambda authorizer."
  policy      = data.aws_iam_policy_document.lambda_authorizer.json

  tags = {
    Name = "${var.name_prefix}-lambda-authorizer-policy"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_authorizer" {
  role       = aws_iam_role.lambda_authorizer.name
  policy_arn = aws_iam_policy.lambda_authorizer.arn
}

# ---------------------------------------------------------------------------
# Step Functions policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "step_functions" {
  statement {
    sid    = "SendPriorityQueueMessages"
    effect = "Allow"

    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = values(var.sqs_queue_arns)
  }

  statement {
    sid    = "ManageWorkflowRecords"
    effect = "Allow"

    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem"
    ]

    resources = values(var.dynamodb_table_arns)
  }

  statement {
    sid       = "PublishWorkflowNotifications"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }

  statement {
    sid    = "ConfigureWorkflowLogging"
    effect = "Allow"

    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "UseEncryptedQueuesAndNotifications"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "sqs.${var.aws_region}.amazonaws.com",
        "sns.${var.aws_region}.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_policy" "step_functions" {
  name        = "${var.name_prefix}-step-functions-policy"
  description = "Initial workflow permissions used by Step Functions."
  policy      = data.aws_iam_policy_document.step_functions.json

  tags = {
    Name = "${var.name_prefix}-step-functions-policy"
  }
}

resource "aws_iam_role_policy_attachment" "step_functions" {
  role       = aws_iam_role.step_functions.name
  policy_arn = aws_iam_policy.step_functions.arn
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eventbridge_scheduler" {
  statement {
    sid       = "InvokeScheduledJobDispatcher"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.job_receiver_function_arn]
  }
}

resource "aws_iam_policy" "eventbridge_scheduler" {
  name        = "${var.name_prefix}-eventbridge-scheduler-policy"
  description = "Allows EventBridge Scheduler to start the OpenClaw workflow."
  policy      = data.aws_iam_policy_document.eventbridge_scheduler.json

  tags = {
    Name = "${var.name_prefix}-eventbridge-scheduler-policy"
  }
}

resource "aws_iam_role_policy_attachment" "eventbridge_scheduler" {
  role       = aws_iam_role.eventbridge_scheduler.name
  policy_arn = aws_iam_policy.eventbridge_scheduler.arn
}

# ---------------------------------------------------------------------------
# EventBridge Pipes policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eventbridge_pipes" {
  statement {
    sid    = "ConsumePriorityQueues"
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = values(var.sqs_queue_arns)
  }

  statement {
    sid       = "DecryptPriorityQueueMessages"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "sqs.${var.aws_region}.amazonaws.com"
      ]
    }
  }

  statement {
    sid       = "RunOpenClawTask"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [local.ecs_task_definition_arn]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.ecs_cluster_arn]
    }
  }

  statement {
    sid     = "PassOpenClawTaskRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]

    resources = [
      aws_iam_role.ecs_task.arn,
      aws_iam_role.ecs_task_execution.arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"

      values = [
        "ecs-tasks.amazonaws.com"
      ]
    }
  }

  statement {
    sid    = "WritePipeLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${local.eventbridge_pipes_log_group_arn}:*"
    ]
  }
}

resource "aws_iam_policy" "eventbridge_pipes" {
  name        = "${var.name_prefix}-eventbridge-pipes-policy"
  description = "Allows EventBridge Pipes to consume SQS messages and start OpenClaw ECS tasks."
  policy      = data.aws_iam_policy_document.eventbridge_pipes.json

  tags = {
    Name = "${var.name_prefix}-eventbridge-pipes-policy"
  }
}

resource "aws_iam_role_policy_attachment" "eventbridge_pipes" {
  role       = aws_iam_role.eventbridge_pipes.name
  policy_arn = aws_iam_policy.eventbridge_pipes.arn
}
