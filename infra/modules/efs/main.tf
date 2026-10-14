locals {
  mount_target_subnets = {
    primary   = var.subnet_ids[0]
    secondary = var.subnet_ids[1]
  }
}

resource "aws_efs_file_system" "this" {
  creation_token = "${var.name_prefix}-runtime"

  encrypted        = true
  kms_key_id       = var.kms_key_arn
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name      = "${var.name_prefix}-runtime"
    Purpose   = "demo-runtime-storage"
    Temporary = "true"
  }
}

resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = "DISABLED"
  }
}

resource "aws_efs_mount_target" "this" {
  for_each = local.mount_target_subnets

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [var.security_group_id]
}

resource "aws_efs_access_point" "runtime" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = var.posix_user_id
    gid = var.posix_group_id
  }

  root_directory {
    path = var.access_point_path

    creation_info {
      owner_uid   = var.posix_user_id
      owner_gid   = var.posix_group_id
      permissions = var.root_directory_permissions
    }
  }

  tags = {
    Name = "${var.name_prefix}-runtime-access-point"
  }
}
