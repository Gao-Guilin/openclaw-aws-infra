locals {
  priority_queues = {
    high = {
      name     = "${var.name_prefix}-high-priority"
      priority = "high"
    }

    medium = {
      name     = "${var.name_prefix}-medium-priority"
      priority = "medium"
    }

    low = {
      name     = "${var.name_prefix}-low-priority"
      priority = "low"
    }
  }
}

resource "aws_sqs_queue" "priority" {
  for_each = local.priority_queues

  name                              = each.value.name
  delay_seconds                     = 0
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  message_retention_seconds         = var.message_retention_seconds
  receive_wait_time_seconds         = var.receive_wait_time_seconds
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = var.kms_data_key_reuse_period_seconds

  tags = {
    Name      = each.value.name
    Priority  = each.value.priority
    QueueType = "task"
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.priority_queues

  name                              = "${each.value.name}-dlq"
  message_retention_seconds         = var.dlq_message_retention_seconds
  receive_wait_time_seconds         = var.receive_wait_time_seconds
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = var.kms_data_key_reuse_period_seconds

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns = [
      aws_sqs_queue.priority[each.key].arn
    ]
  })

  tags = {
    Name      = "${each.value.name}-dlq"
    Priority  = each.value.priority
    QueueType = "dead-letter"
  }
}

resource "aws_sqs_queue_redrive_policy" "priority" {
  for_each = local.priority_queues

  queue_url = aws_sqs_queue.priority[each.key].id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}
