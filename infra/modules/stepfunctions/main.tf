locals {
  state_machine_name = "${var.name_prefix}-workflow"

  supported_task_types = [
    "healthcheck",
    "daily_inspection",
    "cost_inspection",
    "alert_analysis",
    "report_generation"
  ]

  required_string_fields = [
    "job_id",
    "task_type",
    "priority",
    "target"
  ]

  send_message_retry = [
    {
      ErrorEquals     = ["States.TaskFailed"]
      IntervalSeconds = 2
      MaxAttempts     = 3
      BackoffRate     = 2.0
    }
  ]

  send_message_catch = [
    {
      ErrorEquals = ["States.ALL"]
      ResultPath  = "$.dispatch_error"
      Next        = "DispatchFailed"
    }
  ]
}

resource "aws_sfn_state_machine" "workflow" {
  name     = local.state_machine_name
  role_arn = var.role_arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment        = "Validate an OpenClaw-AWS job and dispatch it to the selected priority SQS queue."
    QueryLanguage  = "JSONPath"
    StartAt        = "ValidateRequiredFields"
    TimeoutSeconds = var.execution_timeout_seconds

    States = {
      ValidateRequiredFields = {
        Type = "Choice"

        Choices = [
          {
            And = [
              for field in local.required_string_fields : {
                Variable  = "$.${field}"
                IsPresent = true
              }
            ]

            Next = "ValidateFieldTypes"
          }
        ]

        Default = "InvalidRequest"
      }

      ValidateFieldTypes = {
        Type = "Choice"

        Choices = [
          {
            And = [
              for field in local.required_string_fields : {
                Variable = "$.${field}"
                IsString = true
              }
            ]

            Next = "ValidateTaskType"
          }
        ]

        Default = "InvalidRequest"
      }

      ValidateTaskType = {
        Type = "Choice"

        Choices = [
          {
            Or = [
              for task_type in local.supported_task_types : {
                Variable     = "$.task_type"
                StringEquals = task_type
              }
            ]

            Next = "ValidateTarget"
          }
        ]

        Default = "UnsupportedTaskType"
      }

      ValidateTarget = {
        Type = "Choice"

        Choices = [
          {
            Variable     = "$.target"
            StringEquals = "aws-account"
            Next         = "RouteByPriority"
          }
        ]

        Default = "UnsupportedTarget"
      }

      RouteByPriority = {
        Type = "Choice"

        Choices = [
          {
            Variable     = "$.priority"
            StringEquals = "high"
            Next         = "SendToHighPriorityQueue"
          },
          {
            Variable     = "$.priority"
            StringEquals = "medium"
            Next         = "SendToMediumPriorityQueue"
          },
          {
            Variable     = "$.priority"
            StringEquals = "low"
            Next         = "SendToLowPriorityQueue"
          }
        ]

        Default = "UnsupportedPriority"
      }

      SendToHighPriorityQueue = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"

        Parameters = {
          QueueUrl        = var.sqs_queue_urls["high"]
          "MessageBody.$" = "States.JsonToString($)"

          MessageAttributes = {
            Priority = {
              DataType        = "String"
              "StringValue.$" = "$.priority"
            }

            TaskType = {
              DataType        = "String"
              "StringValue.$" = "$.task_type"
            }
          }
        }

        ResultPath = null
        Retry      = local.send_message_retry
        Catch      = local.send_message_catch
        End        = true
      }

      SendToMediumPriorityQueue = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"

        Parameters = {
          QueueUrl        = var.sqs_queue_urls["medium"]
          "MessageBody.$" = "States.JsonToString($)"

          MessageAttributes = {
            Priority = {
              DataType        = "String"
              "StringValue.$" = "$.priority"
            }

            TaskType = {
              DataType        = "String"
              "StringValue.$" = "$.task_type"
            }
          }
        }

        ResultPath = null
        Retry      = local.send_message_retry
        Catch      = local.send_message_catch
        End        = true
      }

      SendToLowPriorityQueue = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"

        Parameters = {
          QueueUrl        = var.sqs_queue_urls["low"]
          "MessageBody.$" = "States.JsonToString($)"

          MessageAttributes = {
            Priority = {
              DataType        = "String"
              "StringValue.$" = "$.priority"
            }

            TaskType = {
              DataType        = "String"
              "StringValue.$" = "$.task_type"
            }
          }
        }

        ResultPath = null
        Retry      = local.send_message_retry
        Catch      = local.send_message_catch
        End        = true
      }

      InvalidRequest = {
        Type  = "Fail"
        Error = "InvalidRequest"
        Cause = "job_id, task_type, priority, and target must all be present as strings."
      }

      UnsupportedTaskType = {
        Type  = "Fail"
        Error = "UnsupportedTaskType"
        Cause = "The requested task_type is not supported by the current OpenClaw Agent image."
      }

      UnsupportedTarget = {
        Type  = "Fail"
        Error = "UnsupportedTarget"
        Cause = "The first deployment supports only target=aws-account."
      }

      UnsupportedPriority = {
        Type  = "Fail"
        Error = "UnsupportedPriority"
        Cause = "priority must be high, medium, or low."
      }

      DispatchFailed = {
        Type  = "Fail"
        Error = "QueueDispatchFailed"
        Cause = "Step Functions could not dispatch the job to the selected SQS queue."
      }
    }
  })

  logging_configuration {
    log_destination        = "${var.cloudwatch_log_group_arn}:*"
    include_execution_data = var.include_execution_data
    level                  = var.log_level
  }

  tags = {
    Name = local.state_machine_name
  }
}
