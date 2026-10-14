output "ecs_task_execution_role_name" {
  description = "Name of the ECS task execution role."
  value       = aws_iam_role.ecs_task_execution.name
}

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role."
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_name" {
  description = "Name of the ECS task role."
  value       = aws_iam_role.ecs_task.name
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role."
  value       = aws_iam_role.ecs_task.arn
}

output "lambda_job_receiver_role_name" {
  description = "Name of the Lambda job receiver role."
  value       = aws_iam_role.lambda_job_receiver.name
}

output "lambda_job_receiver_role_arn" {
  description = "ARN of the Lambda job receiver role."
  value       = aws_iam_role.lambda_job_receiver.arn
}

output "step_functions_role_name" {
  description = "Name of the Step Functions execution role."
  value       = aws_iam_role.step_functions.name
}

output "step_functions_role_arn" {
  description = "ARN of the Step Functions execution role."
  value       = aws_iam_role.step_functions.arn
}

output "eventbridge_scheduler_role_name" {
  description = "Name of the EventBridge Scheduler execution role."
  value       = aws_iam_role.eventbridge_scheduler.name
}

output "eventbridge_scheduler_role_arn" {
  description = "ARN of the EventBridge Scheduler execution role."
  value       = aws_iam_role.eventbridge_scheduler.arn
}

output "ecs_task_execution_policy_arn" {
  description = "ARN of the ECS task execution policy."
  value       = aws_iam_policy.ecs_task_execution.arn
}

output "ecs_task_policy_arn" {
  description = "ARN of the ECS task runtime policy."
  value       = aws_iam_policy.ecs_task.arn
}

output "lambda_job_receiver_policy_arn" {
  description = "ARN of the Lambda job receiver policy."
  value       = aws_iam_policy.lambda_job_receiver.arn
}

output "step_functions_policy_arn" {
  description = "ARN of the Step Functions policy."
  value       = aws_iam_policy.step_functions.arn
}

output "lambda_authorizer_role_name" {
  description = "Name of the Lambda authorizer role."
  value       = aws_iam_role.lambda_authorizer.name
}

output "lambda_authorizer_role_arn" {
  description = "ARN of the Lambda authorizer role."
  value       = aws_iam_role.lambda_authorizer.arn
}

output "eventbridge_pipes_role_name" {
  description = "Name of the EventBridge Pipes execution role."
  value       = aws_iam_role.eventbridge_pipes.name
}

output "eventbridge_pipes_role_arn" {
  description = "ARN of the EventBridge Pipes execution role."
  value       = aws_iam_role.eventbridge_pipes.arn
}

output "lambda_authorizer_policy_arn" {
  description = "ARN of the Lambda authorizer policy."
  value       = aws_iam_policy.lambda_authorizer.arn
}

output "eventbridge_scheduler_policy_arn" {
  description = "ARN of the EventBridge Scheduler policy."
  value       = aws_iam_policy.eventbridge_scheduler.arn
}

output "eventbridge_pipes_policy_arn" {
  description = "ARN of the EventBridge Pipes policy."
  value       = aws_iam_policy.eventbridge_pipes.arn
}
