data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "key_policy" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "logs.${var.aws_region}.amazonaws.com"
      ]
    }

    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]

    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"

      values = [
        "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
      ]
    }
  }

  statement {
    sid    = "AllowBudgetsEncryptedSNSPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"

      values = [
        "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:*"
      ]
    }
  }

  statement {
    sid    = "AllowCloudWatchEncryptedSNSPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"

      values = [
        "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:*"
      ]
    }
  }
}

resource "aws_kms_key" "this" {
  description                        = "Customer managed KMS key for the OpenClaw-AWS project."
  deletion_window_in_days            = var.deletion_window_in_days
  enable_key_rotation                = var.enable_key_rotation
  is_enabled                         = true
  key_usage                          = "ENCRYPT_DECRYPT"
  multi_region                       = false
  policy                             = data.aws_iam_policy_document.key_policy.json
  bypass_policy_lockout_safety_check = false

  tags = {
    Name = "${var.name_prefix}-kms"
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.this.key_id
}
