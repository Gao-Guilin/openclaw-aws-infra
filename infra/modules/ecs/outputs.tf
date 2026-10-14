output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "task_definition_family" {
  description = "Family name of the OpenClaw Agent task definition."
  value       = aws_ecs_task_definition.agent.family
}

output "task_definition_arn" {
  description = "ARN of the active OpenClaw Agent task definition revision."
  value       = aws_ecs_task_definition.agent.arn
}

output "task_definition_revision" {
  description = "Revision number of the OpenClaw Agent task definition."
  value       = aws_ecs_task_definition.agent.revision
}

output "container_name" {
  description = "Container name used by ECS task overrides and EventBridge Pipes."
  value       = local.container_name
}

output "task_cpu" {
  description = "Configured Fargate task CPU units."
  value       = var.task_cpu
}

output "task_memory" {
  description = "Configured Fargate task memory in MiB."
  value       = var.task_memory
}

output "runtime_mount_path" {
  description = "EFS-backed runtime path inside the container."
  value       = var.runtime_mount_path
}

output "container_insights_enabled" {
  description = "Whether ECS Container Insights is enabled for the cluster."
  value       = var.container_insights_enabled
}
