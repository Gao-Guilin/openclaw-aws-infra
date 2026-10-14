output "state_machine_name" {
  description = "Name of the OpenClaw-AWS state machine."
  value       = aws_sfn_state_machine.workflow.name
}

output "state_machine_arn" {
  description = "ARN of the OpenClaw-AWS state machine."
  value       = aws_sfn_state_machine.workflow.arn
}

output "state_machine_id" {
  description = "Terraform resource ID of the OpenClaw-AWS state machine."
  value       = aws_sfn_state_machine.workflow.id
}

output "state_machine_type" {
  description = "Type of the OpenClaw-AWS state machine."
  value       = aws_sfn_state_machine.workflow.type
}

output "supported_task_types" {
  description = "Task types accepted by the first workflow version."
  value       = local.supported_task_types
}
