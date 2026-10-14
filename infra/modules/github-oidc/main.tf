data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  github_repository_parts = split("/", var.github_repository)
  github_owner            = local.github_repository_parts[0]
  github_repository_name  = local.github_repository_parts[1]

  classic_branch_subjects = [
    for branch in sort(tolist(var.github_branch_patterns)) :
    "repo:${var.github_repository}:ref:refs/heads/${branch}"
  ]
  immutable_branch_subjects = [
    for branch in sort(tolist(var.github_branch_patterns)) :
    "repo:${local.github_owner}@*/${local.github_repository_name}@*:ref:refs/heads/${branch}"
  ]
  environment_subjects = [
    for environment in sort(tolist(var.github_environment_names)) :
    "repo:${var.github_repository}:environment:${environment}"
  ]
  immutable_environment_subjects = [
    for environment in sort(tolist(var.github_environment_names)) :
    "repo:${local.github_owner}@*/${local.github_repository_name}@*:environment:${environment}"
  ]

  branch_subjects = distinct(concat(
    local.classic_branch_subjects,
    local.immutable_branch_subjects
  ))
  deploy_environment_subjects = distinct(concat(
    local.environment_subjects,
    local.immutable_environment_subjects
  ))
  cd_allowed_subjects = distinct(concat(
    local.branch_subjects,
    local.deploy_environment_subjects
  ))

  inferred_environment_name = element(reverse(split("-", var.name_prefix)), 0)
  environment_name          = coalesce(var.environment_name, local.inferred_environment_name)
  other_environment_name    = local.environment_name == "prod" ? "dev" : "prod"
  terraform_state_key       = coalesce(var.terraform_state_key, "envs/${local.environment_name}/terraform.tfstate")

  image_repository_arns = distinct(concat(
    [var.ecr_repository_arn],
    var.additional_ecr_repository_arns
  ))

  # The deployment role is intentionally denied access to the sibling environment.
  # Create APIs that do not support resource-level permissions remain limited by the
  # workflow trust policy, project IAM naming, request/resource tags, and reviewed Plan.
  other_environment_resource_arns = [
    "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alias/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:pipes:${var.aws_region}:${data.aws_caller_identity.current.account_id}:pipe/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/*/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule-group/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:s3:::${var.project_resource_prefix}-${local.other_environment_name}-*",
    "arn:${data.aws_partition.current.partition}:s3:::${var.project_resource_prefix}-${local.other_environment_name}-*/*"
  ]

  terraform_read_actions = [
    "apigateway:GET",
    "budgets:Describe*",
    "budgets:ViewBudget",
    "cloudwatch:Describe*",
    "cloudwatch:Get*",
    "cloudwatch:List*",
    "dynamodb:Describe*",
    "dynamodb:List*",
    "ec2:Describe*",
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:Describe*",
    "ecr:GetDownloadUrlForLayer",
    "ecr:GetLifecyclePolicy",
    "ecr:GetLifecyclePolicyPreview",
    "ecr:GetRepositoryPolicy",
    "ecr:ListImages",
    "ecr:ListTagsForResource",
    "ecs:Describe*",
    "ecs:List*",
    "elasticfilesystem:Describe*",
    "events:Describe*",
    "events:List*",
    "events:TestEventPattern",
    "iam:Get*",
    "iam:List*",
    "kms:DescribeKey",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListResourceTags",
    "lambda:Get*",
    "lambda:List*",
    "logs:Describe*",
    "logs:Get*",
    "logs:List*",
    "pipes:GetPipe",
    "pipes:ListPipes",
    "pipes:ListTagsForResource",
    "s3:GetAccelerateConfiguration",
    "s3:GetAnalyticsConfiguration",
    "s3:GetBucket*",
    "s3:GetEncryptionConfiguration",
    "s3:GetIntelligentTieringConfiguration",
    "s3:GetInventoryConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetMetricsConfiguration",
    "s3:GetObjectAttributes",
    "s3:GetReplicationConfiguration",
    "s3:ListAllMyBuckets",
    "s3:ListBucket",
    "s3:ListBucketVersions",
    "scheduler:GetSchedule",
    "scheduler:GetScheduleGroup",
    "scheduler:ListScheduleGroups",
    "scheduler:ListSchedules",
    "scheduler:ListTagsForResource",
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:ListSecrets",
    "secretsmanager:ListSecretVersionIds",
    "sns:Get*",
    "sns:List*",
    "sqs:GetQueueAttributes",
    "sqs:GetQueueUrl",
    "sqs:ListDeadLetterSourceQueues",
    "sqs:ListQueueTags",
    "sqs:ListQueues",
    "states:Describe*",
    "states:List*",
    "sts:GetCallerIdentity",
    "tag:GetResources",
    "tag:GetTagKeys",
    "tag:GetTagValues",
  ]

  terraform_compute_actions = [
    "apigateway:DELETE",
    "apigateway:GET",
    "apigateway:PATCH",
    "apigateway:POST",
    "apigateway:PUT",
    "ec2:AssociateRouteTable",
    "ec2:AttachInternetGateway",
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:CreateInternetGateway",
    "ec2:CreateRoute",
    "ec2:CreateRouteTable",
    "ec2:CreateSecurityGroup",
    "ec2:CreateSubnet",
    "ec2:CreateTags",
    "ec2:CreateVpc",
    "ec2:DeleteInternetGateway",
    "ec2:DeleteRoute",
    "ec2:DeleteRouteTable",
    "ec2:DeleteSecurityGroup",
    "ec2:DeleteSubnet",
    "ec2:DeleteTags",
    "ec2:DeleteVpc",
    "ec2:Describe*",
    "ec2:DetachInternetGateway",
    "ec2:DisassociateRouteTable",
    "ec2:ModifySecurityGroupRules",
    "ec2:ModifySubnetAttribute",
    "ec2:ModifyVpcAttribute",
    "ec2:ReplaceRoute",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress",
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchDeleteImage",
    "ecr:BatchGetImage",
    "ecr:CompleteLayerUpload",
    "ecr:CreateRepository",
    "ecr:DeleteLifecyclePolicy",
    "ecr:DeleteRepository",
    "ecr:DeleteRepositoryPolicy",
    "ecr:Describe*",
    "ecr:Get*",
    "ecr:InitiateLayerUpload",
    "ecr:List*",
    "ecr:PutImage",
    "ecr:PutLifecyclePolicy",
    "ecr:SetRepositoryPolicy",
    "ecr:TagResource",
    "ecr:UntagResource",
    "ecr:UploadLayerPart",
    "ecs:CreateCluster",
    "ecs:DeleteCluster",
    "ecs:DeregisterTaskDefinition",
    "ecs:Describe*",
    "ecs:List*",
    "ecs:PutClusterCapacityProviders",
    "ecs:RegisterTaskDefinition",
    "ecs:RunTask",
    "ecs:StopTask",
    "ecs:TagResource",
    "ecs:UntagResource",
    "ecs:UpdateCluster",
    "ecs:UpdateClusterSettings",
    "elasticfilesystem:CreateAccessPoint",
    "elasticfilesystem:CreateFileSystem",
    "elasticfilesystem:CreateMountTarget",
    "elasticfilesystem:DeleteAccessPoint",
    "elasticfilesystem:DeleteBackupPolicy",
    "elasticfilesystem:DeleteFileSystem",
    "elasticfilesystem:DeleteFileSystemPolicy",
    "elasticfilesystem:DeleteMountTarget",
    "elasticfilesystem:Describe*",
    "elasticfilesystem:PutBackupPolicy",
    "elasticfilesystem:PutFileSystemPolicy",
    "elasticfilesystem:PutLifecycleConfiguration",
    "elasticfilesystem:TagResource",
    "elasticfilesystem:UntagResource",
    "events:DeleteRule",
    "events:DescribeRule",
    "events:List*",
    "events:PutRule",
    "events:PutTargets",
    "events:RemoveTargets",
    "events:TagResource",
    "events:UntagResource",
    "lambda:AddPermission",
    "lambda:CreateFunction",
    "lambda:DeleteFunction",
    "lambda:DeleteFunctionConcurrency",
    "lambda:Get*",
    "lambda:List*",
    "lambda:PutFunctionConcurrency",
    "lambda:RemovePermission",
    "lambda:TagResource",
    "lambda:UntagResource",
    "lambda:UpdateFunctionCode",
    "lambda:UpdateFunctionConfiguration",
    "logs:CreateLogGroup",
    "logs:DeleteLogGroup",
    "logs:DeleteRetentionPolicy",
    "logs:Describe*",
    "logs:List*",
    "logs:PutRetentionPolicy",
    "logs:TagResource",
    "logs:UntagResource",
    "pipes:CreatePipe",
    "pipes:DeletePipe",
    "pipes:GetPipe",
    "pipes:List*",
    "pipes:StartPipe",
    "pipes:StopPipe",
    "pipes:TagResource",
    "pipes:UntagResource",
    "pipes:UpdatePipe",
    "scheduler:CreateSchedule",
    "scheduler:DeleteSchedule",
    "scheduler:GetSchedule",
    "scheduler:List*",
    "scheduler:TagResource",
    "scheduler:UntagResource",
    "scheduler:UpdateSchedule",
    "states:CreateStateMachine",
    "states:DeleteStateMachine",
    "states:Describe*",
    "states:List*",
    "states:StartExecution",
    "states:StopExecution",
    "states:TagResource",
    "states:UntagResource",
    "states:UpdateStateMachine",
  ]

  terraform_data_actions = [
    "budgets:CreateBudget",
    "budgets:CreateNotification",
    "budgets:CreateSubscriber",
    "budgets:DeleteBudget",
    "budgets:DeleteNotification",
    "budgets:DeleteSubscriber",
    "budgets:Describe*",
    "budgets:ModifyBudget",
    "budgets:UpdateNotification",
    "budgets:UpdateSubscriber",
    "budgets:ViewBudget",
    "cloudwatch:DeleteAlarms",
    "cloudwatch:Describe*",
    "cloudwatch:Get*",
    "cloudwatch:List*",
    "cloudwatch:PutMetricAlarm",
    "cloudwatch:TagResource",
    "cloudwatch:UntagResource",
    "dynamodb:CreateTable",
    "dynamodb:DeleteTable",
    "dynamodb:Describe*",
    "dynamodb:List*",
    "dynamodb:TagResource",
    "dynamodb:UntagResource",
    "dynamodb:UpdateContinuousBackups",
    "dynamodb:UpdateTable",
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:CreateKey",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:DisableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:List*",
    "kms:PutKeyPolicy",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
    "secretsmanager:CreateSecret",
    "secretsmanager:DeleteResourcePolicy",
    "secretsmanager:DeleteSecret",
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:List*",
    "secretsmanager:PutResourcePolicy",
    "secretsmanager:RestoreSecret",
    "secretsmanager:TagResource",
    "secretsmanager:UntagResource",
    "s3:CreateBucket",
    "s3:DeleteBucket",
    "s3:DeleteBucketPolicy",
    "s3:DeleteBucketTagging",
    "s3:DeleteBucketWebsite",
    "s3:DeleteBucket*",
    "s3:DeleteObject",
    "s3:DeleteObjectVersion",
    "s3:DeleteLifecycleConfiguration",
    "s3:GetBucket*",
    "s3:GetEncryptionConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetObject",
    "s3:GetObjectAcl",
    "s3:GetObjectTagging",
    "s3:ListAllMyBuckets",
    "s3:ListBucket",
    "s3:PutBucket*",
    "s3:PutEncryptionConfiguration",
    "s3:PutLifecycleConfiguration",
    "s3:PutObject",
    "s3:PutObjectAcl",
    "s3:PutObjectTagging",
    "sns:CreateTopic",
    "sns:DeleteTopic",
    "sns:Get*",
    "sns:List*",
    "sns:SetTopicAttributes",
    "sns:Subscribe",
    "sns:TagResource",
    "sns:Unsubscribe",
    "sns:UntagResource",
    "sqs:CreateQueue",
    "sqs:DeleteQueue",
    "sqs:GetQueueAttributes",
    "sqs:GetQueueUrl",
    "sqs:List*",
    "sqs:PurgeQueue",
    "sqs:SetQueueAttributes",
    "sqs:TagQueue",
    "sqs:UntagQueue",
    "sts:GetCallerIdentity",
  ]

  # Deployment writes are split by authorization model:
  # - predictably named resources are constrained to the current environment ARN namespace;
  # - ID-based creates require an explicit Environment request tag;
  # - ID-based updates/deletes require an existing Environment resource tag.
  current_environment_compute_resource_arns = [
    "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${var.name_prefix}-*/*",
    "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*${var.name_prefix}-*:*",
    "arn:${data.aws_partition.current.partition}:pipes:${var.aws_region}:${data.aws_caller_identity.current.account_id}:pipe/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/*/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.name_prefix}-*"
  ]

  current_environment_data_resource_arns = [
    "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-*/*",
    "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*",
    "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"
  ]

  current_environment_kms_alias_arns = [
    "arn:${data.aws_partition.current.partition}:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alias/${var.name_prefix}-*"
  ]

  # These APIs create resources whose ARN contains an AWS-generated identifier.
  # Terraform must send the Environment tag in the create request.
  tagged_compute_create_actions = [
    "ec2:CreateInternetGateway",
    "ec2:CreateRouteTable",
    "ec2:CreateSecurityGroup",
    "ec2:CreateSubnet",
    "ec2:CreateVpc",
    "ecs:RegisterTaskDefinition",
    "elasticfilesystem:CreateAccessPoint",
    "elasticfilesystem:CreateFileSystem"
  ]

  tagged_compute_resource_actions = [
    "ec2:AssociateRouteTable",
    "ec2:AttachInternetGateway",
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:CreateRoute",
    "ec2:DeleteInternetGateway",
    "ec2:DeleteRoute",
    "ec2:DeleteRouteTable",
    "ec2:DeleteSecurityGroup",
    "ec2:DeleteSubnet",
    "ec2:DeleteTags",
    "ec2:DeleteVpc",
    "ec2:DetachInternetGateway",
    "ec2:DisassociateRouteTable",
    "ec2:ModifySecurityGroupRules",
    "ec2:ModifySubnetAttribute",
    "ec2:ModifyVpcAttribute",
    "ec2:ReplaceRoute",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress",
    "ec2:CreateTags",
    "elasticfilesystem:CreateMountTarget",
    "elasticfilesystem:DeleteAccessPoint",
    "elasticfilesystem:DeleteBackupPolicy",
    "elasticfilesystem:DeleteFileSystem",
    "elasticfilesystem:DeleteFileSystemPolicy",
    "elasticfilesystem:DeleteMountTarget",
    "elasticfilesystem:PutBackupPolicy",
    "elasticfilesystem:PutFileSystemPolicy",
    "elasticfilesystem:PutLifecycleConfiguration",
    "elasticfilesystem:TagResource",
    "elasticfilesystem:UntagResource"
  ]

  tagged_compute_request_actions = concat(
    local.tagged_compute_create_actions,
    [
      "ec2:CreateTags",
      "elasticfilesystem:TagResource"
    ]
  )

  current_environment_compute_named_actions = [
    "ecr:*",
    "ecs:*",
    "events:*",
    "lambda:*",
    "logs:*",
    "pipes:*",
    "scheduler:*",
    "states:*"
  ]

  current_environment_data_named_actions = [
    "budgets:*",
    "cloudwatch:*",
    "dynamodb:*",
    "s3:*",
    "secretsmanager:*",
    "sns:*",
    "sqs:*"
  ]

  tagged_kms_request_actions = [
    "kms:CreateKey",
    "kms:TagResource"
  ]

  tagged_kms_resource_actions = [
    "kms:CancelKeyDeletion",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:PutKeyPolicy",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateKeyDescription"
  ]

  kms_alias_actions = [
    "kms:CreateAlias",
    "kms:DeleteAlias",
    "kms:UpdateAlias"
  ]
}

# ---------------------------------------------------------------------------
# GitHub OIDC trust policies
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cd_assume_role" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.cd_allowed_subjects
    }
  }
}

data "aws_iam_policy_document" "plan_assume_role" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.branch_subjects
    }
  }
}

data "aws_iam_policy_document" "deploy_assume_role" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_environment_subjects
    }
  }
}

# ---------------------------------------------------------------------------
# Image delivery role (existing stable resource identity)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cd" {
  name                 = "${var.name_prefix}-cd-role"
  description          = "Short-lived GitHub Actions role for OpenClaw Agent image delivery."
  assume_role_policy   = data.aws_iam_policy_document.cd_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-cd-role"
  }
}

data "aws_iam_policy_document" "cd" {
  statement {
    sid       = "GetECRAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "DeliverAgentImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload", "ecr:DescribeImages",
      "ecr:DescribeRepositories", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:ListImages", "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = local.image_repository_arns
  }

  statement {
    sid       = "VerifyRuntime"
    effect    = "Allow"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:DescribeTasks", "ecs:ListTasks"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cd" {
  name        = "${var.name_prefix}-cd-policy"
  description = "Least-privilege permissions for GitHub Actions basic CD."
  policy      = data.aws_iam_policy_document.cd.json

  tags = {
    Name = "${var.name_prefix}-cd-policy"
  }
}

resource "aws_iam_role_policy_attachment" "cd" {
  role       = aws_iam_role.cd.name
  policy_arn = aws_iam_policy.cd.arn
}

# ---------------------------------------------------------------------------
# Read-only Terraform Plan role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  count = var.terraform_deploy_enabled ? 1 : 0

  name                 = "${var.name_prefix}-plan-role"
  description          = "GitHub Actions role for read-only Terraform planning and immutable image promotion."
  assume_role_policy   = data.aws_iam_policy_document.plan_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-plan-role"
  }
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "DenySecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:BatchGetSecretValue", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecret"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAWSControlPlane"
    effect    = "Allow"
    actions   = local.terraform_read_actions
    resources = ["*"]
  }

  statement {
    sid       = "GetECRAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PromoteValidatedImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload", "ecr:DescribeImages",
      "ecr:DescribeRepositories", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:ListImages", "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = local.image_repository_arns
  }

  statement {
    sid       = "ReadTerraformStateBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}"]
  }

  statement {
    sid       = "ListTerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        local.terraform_state_key,
        "${local.terraform_state_key}.tflock",
        "${dirname(local.terraform_state_key)}/*"
      ]
    }
  }

  statement {
    sid       = "ReadTerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}/${local.terraform_state_key}"]
  }

  statement {
    sid    = "ManageTerraformStateLock"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}/${local.terraform_state_key}.tflock"]
  }
}

resource "aws_iam_policy" "plan" {
  count = var.terraform_deploy_enabled ? 1 : 0

  name        = "${var.name_prefix}-plan-policy"
  description = "Restricted write permissions needed for Terraform planning and image promotion."
  policy      = data.aws_iam_policy_document.plan.json

  tags = {
    Name = "${var.name_prefix}-plan-policy"
  }
}

resource "aws_iam_role_policy_attachment" "plan_custom" {
  count = var.terraform_deploy_enabled ? 1 : 0

  role       = aws_iam_role.plan[0].name
  policy_arn = aws_iam_policy.plan[0].arn
}

# ---------------------------------------------------------------------------
# Approved Terraform Apply role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "deploy" {
  count = var.terraform_deploy_enabled ? 1 : 0

  name                 = "${var.name_prefix}-deploy-role"
  description          = "GitHub Actions role for approved Terraform Apply operations."
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-deploy-role"
  }
}

data "aws_iam_policy_document" "deploy_control" {
  statement {
    sid       = "DenySecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:BatchGetSecretValue", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecret"]
    resources = ["*"]
  }

  statement {
    sid       = "DenySiblingEnvironmentResources"
    effect    = "Deny"
    actions   = ["*"]
    resources = local.other_environment_resource_arns
  }

  statement {
    sid       = "ReadAWSControlPlane"
    effect    = "Allow"
    actions   = local.terraform_read_actions
    resources = ["*"]
  }

  statement {
    sid    = "ManageCurrentEnvironmentIAMResources"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy", "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:CreateRole",
      "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:DeleteRole", "iam:DetachRolePolicy",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetRole", "iam:ListAttachedRolePolicies",
      "iam:ListEntitiesForPolicy", "iam:ListInstanceProfilesForRole", "iam:ListPolicyTags",
      "iam:ListPolicyVersions", "iam:ListRolePolicies", "iam:ListRoleTags",
      "iam:TagPolicy", "iam:TagRole", "iam:UntagPolicy", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:UpdateRoleDescription"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.name_prefix}-*"
    ]
  }

  statement {
    sid     = "PassCurrentEnvironmentRolesToAWS"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-*"
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ecs-tasks.amazonaws.com",
        "events.amazonaws.com",
        "lambda.amazonaws.com",
        "pipes.amazonaws.com",
        "scheduler.amazonaws.com",
        "states.amazonaws.com"
      ]
    }
  }

  statement {
    sid       = "ReadTerraformStateBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}"]
  }

  statement {
    sid       = "ListTerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        local.terraform_state_key,
        "${local.terraform_state_key}.tflock",
        "${dirname(local.terraform_state_key)}/*"
      ]
    }
  }

  statement {
    sid    = "ManageTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}/${local.terraform_state_key}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}/${local.terraform_state_key}.tflock"
    ]
  }
}

data "aws_iam_policy_document" "deploy_compute" {
  statement {
    sid       = "ManageNamedCurrentEnvironmentComputeResources"
    effect    = "Allow"
    actions   = local.current_environment_compute_named_actions
    resources = local.current_environment_compute_resource_arns
  }

  statement {
    sid       = "CreateOrTagCurrentEnvironmentComputeResources"
    effect    = "Allow"
    actions   = local.tagged_compute_request_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [local.environment_name]
    }
  }

  statement {
    sid       = "ManageTaggedCurrentEnvironmentComputeResources"
    effect    = "Allow"
    actions   = local.tagged_compute_resource_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [local.environment_name]
    }
  }

  statement {
    sid       = "CreateCurrentEnvironmentApiGateway"
    effect    = "Allow"
    actions   = ["apigateway:POST"]
    resources = ["arn:${data.aws_partition.current.partition}:apigateway:${var.aws_region}::/apis"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [local.environment_name]
    }
  }

  statement {
    sid     = "ManageTaggedCurrentEnvironmentApiGateway"
    effect  = "Allow"
    actions = ["apigateway:DELETE", "apigateway:PATCH", "apigateway:POST", "apigateway:PUT"]
    resources = [
      "arn:${data.aws_partition.current.partition}:apigateway:${var.aws_region}::/apis/*",
      "arn:${data.aws_partition.current.partition}:apigateway:${var.aws_region}::/tags/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [local.environment_name]
    }
  }
}

data "aws_iam_policy_document" "deploy_data" {
  statement {
    sid       = "ManageNamedCurrentEnvironmentDataResources"
    effect    = "Allow"
    actions   = local.current_environment_data_named_actions
    resources = local.current_environment_data_resource_arns
  }

  statement {
    sid       = "CreateOrTagCurrentEnvironmentKMSKeys"
    effect    = "Allow"
    actions   = local.tagged_kms_request_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [local.environment_name]
    }
  }

  statement {
    sid       = "ManageTaggedCurrentEnvironmentKMSKeys"
    effect    = "Allow"
    actions   = local.tagged_kms_resource_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [local.environment_name]
    }
  }

  statement {
    sid       = "ManageCurrentEnvironmentKMSAliases"
    effect    = "Allow"
    actions   = local.kms_alias_actions
    resources = local.current_environment_kms_alias_arns
  }

  statement {
    sid       = "UseCurrentEnvironmentKMSAliasTargets"
    effect    = "Allow"
    actions   = local.kms_alias_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [local.environment_name]
    }
  }
}

resource "aws_iam_policy" "deploy_control" {
  count = var.terraform_deploy_enabled ? 1 : 0

  name        = "${var.name_prefix}-deploy-control-policy"
  description = "Safety, IAM, PassRole, and Terraform State permissions for approved Apply operations."
  policy      = data.aws_iam_policy_document.deploy_control.json

  tags = {
    Name = "${var.name_prefix}-deploy-control-policy"
  }
}

resource "aws_iam_policy" "deploy_compute" {
  count = var.terraform_deploy_enabled ? 1 : 0

  name        = "${var.name_prefix}-deploy-compute-policy"
  description = "Environment-scoped compute and orchestration permissions for approved Apply operations."
  policy      = data.aws_iam_policy_document.deploy_compute.json

  tags = {
    Name = "${var.name_prefix}-deploy-compute-policy"
  }
}

resource "aws_iam_policy" "deploy_data" {
  count = var.terraform_deploy_enabled ? 1 : 0

  name        = "${var.name_prefix}-deploy-data-policy"
  description = "Environment-scoped data, monitoring, and security permissions for approved Apply operations."
  policy      = data.aws_iam_policy_document.deploy_data.json

  tags = {
    Name = "${var.name_prefix}-deploy-data-policy"
  }
}

resource "aws_iam_role_policy_attachment" "deploy_control" {
  count = var.terraform_deploy_enabled ? 1 : 0

  role       = aws_iam_role.deploy[0].name
  policy_arn = aws_iam_policy.deploy_control[0].arn
}

resource "aws_iam_role_policy_attachment" "deploy_compute" {
  count = var.terraform_deploy_enabled ? 1 : 0

  role       = aws_iam_role.deploy[0].name
  policy_arn = aws_iam_policy.deploy_compute[0].arn
}

resource "aws_iam_role_policy_attachment" "deploy_data" {
  count = var.terraform_deploy_enabled ? 1 : 0

  role       = aws_iam_role.deploy[0].name
  policy_arn = aws_iam_policy.deploy_data[0].arn
}
