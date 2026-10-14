locals {
  tables = {
    jobs = {
      name     = "${var.name_prefix}-jobs"
      hash_key = "job_id"
      purpose  = "Task state and execution records."
    }

    alerts = {
      name     = "${var.name_prefix}-alerts"
      hash_key = "alert_id"
      purpose  = "CloudOps alert records."
    }

    reports = {
      name     = "${var.name_prefix}-reports"
      hash_key = "report_id"
      purpose  = "Report metadata and S3 object indexes."
    }
  }
}

resource "aws_dynamodb_table" "this" {
  for_each = local.tables

  name                        = each.value.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = each.value.hash_key
  table_class                 = "STANDARD"
  deletion_protection_enabled = var.deletion_protection_enabled

  attribute {
    name = each.value.hash_key
    type = "S"
  }

  ttl {
    attribute_name = var.ttl_attribute_name
    enabled        = var.ttl_enabled
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery_enabled
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = {
    Name    = each.value.name
    Purpose = each.value.purpose
  }
}
