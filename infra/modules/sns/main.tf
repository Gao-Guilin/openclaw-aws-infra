data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_sns_topic" "notifications" {
  name              = "${var.name_prefix}-notifications"
  kms_master_key_id = var.kms_key_arn

  tags = {
    Name = "${var.name_prefix}-notifications"
  }
}

data "aws_iam_policy_document" "topic_policy" {
  statement {
    sid    = "AllowAccountManagement"
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }

    actions = [
      "sns:AddPermission",
      "sns:DeleteTopic",
      "sns:GetDataProtectionPolicy",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
      "sns:Publish",
      "sns:PutDataProtectionPolicy",
      "sns:RemovePermission",
      "sns:SetTopicAttributes",
      "sns:Subscribe"
    ]

    resources = [
      aws_sns_topic.notifications.arn
    ]
  }

  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions = [
      "sns:Publish"
    ]

    resources = [
      aws_sns_topic.notifications.arn
    ]

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
    sid    = "AllowCloudWatchPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions = [
      "sns:Publish"
    ]

    resources = [
      aws_sns_topic.notifications.arn
    ]

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

resource "aws_sns_topic_policy" "notifications" {
  arn    = aws_sns_topic.notifications.arn
  policy = data.aws_iam_policy_document.topic_policy.json
}


resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.email_subscriptions)

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = each.value
}
