variable "name_prefix" {
  type     = string
  nullable = false
}

variable "pipes_role_arn" {
  type     = string
  nullable = false
}

variable "scheduler_role_arn" {
  type     = string
  nullable = false
}

variable "sqs_queue_arns" {
  type     = map(string)
  nullable = false

  validation {
    condition     = alltrue([for key in ["high", "medium", "low"] : contains(keys(var.sqs_queue_arns), key)])
    error_message = "sqs_queue_arns must contain high, medium, and low keys."
  }
}

variable "ecs_cluster_arn" {
  type     = string
  nullable = false
}

variable "ecs_task_definition_arn" {
  type     = string
  nullable = false
}

variable "ecs_container_name" {
  type     = string
  nullable = false
}

variable "task_cpu" {
  type     = number
  default  = 1024
  nullable = false

  validation {
    condition     = var.task_cpu == 1024
    error_message = "task_cpu must be 1024."
  }
}

variable "task_memory" {
  type     = number
  default  = 4096
  nullable = false

  validation {
    condition     = var.task_memory == 4096
    error_message = "task_memory must be 4096."
  }
}

variable "subnet_ids" {
  type     = list(string)
  nullable = false

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnet IDs are required."
  }
}

variable "security_group_ids" {
  type     = list(string)
  nullable = false

  validation {
    condition     = length(var.security_group_ids) >= 1
    error_message = "At least one security group ID is required."
  }
}

variable "assign_public_ip" {
  type     = bool
  default  = true
  nullable = false
}

variable "fargate_platform_version" {
  type     = string
  default  = "1.4.0"
  nullable = false
}

variable "pipes_log_group_arn" {
  type     = string
  nullable = false
}

variable "pipe_log_level" {
  type     = string
  default  = "INFO"
  nullable = false

  validation {
    condition     = contains(["OFF", "ERROR", "INFO", "TRACE"], var.pipe_log_level)
    error_message = "Invalid pipe_log_level."
  }
}

variable "pipes_enabled" {
  type     = bool
  default  = true
  nullable = false
}

variable "job_receiver_function_arn" {
  type     = string
  nullable = false
}

variable "job_receiver_function_name" {
  type     = string
  nullable = false
}

variable "scheduler_enabled" {
  type     = bool
  default  = false
  nullable = false
}

variable "schedule_timezone" {
  type     = string
  default  = "Asia/Shanghai"
  nullable = false
}

variable "morning_schedule_expression" {
  type     = string
  default  = "cron(0 9 * * ? *)"
  nullable = false
}

variable "afternoon_schedule_expression" {
  type     = string
  default  = "cron(0 16 * * ? *)"
  nullable = false
}

variable "weekly_report_schedule_expression" {
  type     = string
  default  = "cron(30 16 ? * TUE *)"
  nullable = false
}

variable "scheduler_maximum_event_age_seconds" {
  type     = number
  default  = 3600
  nullable = false

  validation {
    condition     = var.scheduler_maximum_event_age_seconds >= 60 && var.scheduler_maximum_event_age_seconds <= 86400
    error_message = "Invalid Scheduler event age."
  }
}

variable "scheduler_maximum_retry_attempts" {
  type     = number
  default  = 2
  nullable = false

  validation {
    condition     = var.scheduler_maximum_retry_attempts >= 0 && var.scheduler_maximum_retry_attempts <= 185
    error_message = "Invalid Scheduler retry count."
  }
}

variable "alert_ingress_enabled" {
  type     = bool
  default  = true
  nullable = false
}

variable "alarm_name_prefix" {
  type     = string
  nullable = false
}

variable "alert_maximum_event_age_seconds" {
  type     = number
  default  = 3600
  nullable = false
}

variable "alert_maximum_retry_attempts" {
  type     = number
  default  = 2
  nullable = false
}
