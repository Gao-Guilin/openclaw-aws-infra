output "pipe_names" { value = { for key, pipe in aws_pipes_pipe.priority : key => pipe.name } }
output "pipe_arns" { value = { for key, pipe in aws_pipes_pipe.priority : key => pipe.arn } }
output "pipe_desired_states" { value = { for key, pipe in aws_pipes_pipe.priority : key => pipe.desired_state } }
output "schedule_names" { value = { for key, schedule in aws_scheduler_schedule.workflow : key => schedule.name } }
output "schedule_arns" { value = { for key, schedule in aws_scheduler_schedule.workflow : key => schedule.arn } }
output "schedule_states" { value = { for key, schedule in aws_scheduler_schedule.workflow : key => schedule.state } }
output "schedule_expressions" { value = { for key, schedule in local.schedules : key => schedule.schedule_expression } }
output "schedule_timezone" { value = var.schedule_timezone }
output "scheduler_enabled" { value = var.scheduler_enabled }
output "pipes_enabled" { value = var.pipes_enabled }
output "cloudwatch_alarm_rule_name" { value = aws_cloudwatch_event_rule.cloudwatch_alarm.name }
output "cloudwatch_alarm_rule_arn" { value = aws_cloudwatch_event_rule.cloudwatch_alarm.arn }
output "alert_ingress_enabled" { value = var.alert_ingress_enabled }
