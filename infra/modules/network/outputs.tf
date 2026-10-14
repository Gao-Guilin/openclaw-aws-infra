output "vpc_id" {
  description = "ID of the OpenClaw-AWS VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the VPC Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value = [
    for key in sort(keys(aws_subnet.public)) :
    aws_subnet.public[key].id
  ]
}

output "public_subnet_availability_zones" {
  description = "Availability Zones used by the public subnets."
  value       = local.selected_availability_zones
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "ecs_task_security_group_id" {
  description = "Security group ID used by ECS Fargate tasks."
  value       = aws_security_group.ecs_tasks.id
}

output "efs_security_group_id" {
  description = "Security group ID used by EFS mount targets."
  value       = aws_security_group.efs.id
}
