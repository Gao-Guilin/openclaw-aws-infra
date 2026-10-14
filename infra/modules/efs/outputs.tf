output "file_system_id" {
  description = "ID of the EFS file system."
  value       = aws_efs_file_system.this.id
}

output "file_system_arn" {
  description = "ARN of the EFS file system."
  value       = aws_efs_file_system.this.arn
}

output "file_system_dns_name" {
  description = "DNS name of the EFS file system."
  value       = aws_efs_file_system.this.dns_name
}

output "access_point_id" {
  description = "ID of the EFS runtime access point."
  value       = aws_efs_access_point.runtime.id
}

output "access_point_arn" {
  description = "ARN of the EFS runtime access point."
  value       = aws_efs_access_point.runtime.arn
}

output "access_point_path" {
  description = "Root directory exposed by the EFS access point."
  value       = var.access_point_path
}

output "mount_target_ids" {
  description = "Map of EFS mount target IDs using stable subnet labels."
  value = {
    for key, mount_target in aws_efs_mount_target.this :
    key => mount_target.id
  }
}
