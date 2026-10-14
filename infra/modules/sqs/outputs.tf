output "queue_names" {
  description = "Map of priority SQS queue names."
  value = {
    for key, queue in aws_sqs_queue.priority :
    key => queue.name
  }
}

output "queue_urls" {
  description = "Map of priority SQS queue URLs."
  value = {
    for key, queue in aws_sqs_queue.priority :
    key => queue.id
  }
}

output "queue_arns" {
  description = "Map of priority SQS queue ARNs."
  value = {
    for key, queue in aws_sqs_queue.priority :
    key => queue.arn
  }
}

output "dlq_names" {
  description = "Map of dead-letter queue names."
  value = {
    for key, queue in aws_sqs_queue.dlq :
    key => queue.name
  }
}

output "dlq_urls" {
  description = "Map of dead-letter queue URLs."
  value = {
    for key, queue in aws_sqs_queue.dlq :
    key => queue.id
  }
}

output "dlq_arns" {
  description = "Map of dead-letter queue ARNs."
  value = {
    for key, queue in aws_sqs_queue.dlq :
    key => queue.arn
  }
}

output "high_priority_queue_url" {
  description = "URL of the high-priority task queue."
  value       = aws_sqs_queue.priority["high"].id
}

output "medium_priority_queue_url" {
  description = "URL of the medium-priority task queue."
  value       = aws_sqs_queue.priority["medium"].id
}

output "low_priority_queue_url" {
  description = "URL of the low-priority task queue."
  value       = aws_sqs_queue.priority["low"].id
}
