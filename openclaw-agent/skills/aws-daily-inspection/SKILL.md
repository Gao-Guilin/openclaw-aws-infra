# aws-daily-inspection

## Purpose

`aws-daily-inspection` performs a lightweight read-only daily inspection of the AWS environment used by the OpenClaw-AWS Agent.

It is designed to run after the basic healthcheck skill is working and before deeper reporting or alert analysis is introduced.

## Scope

This skill performs read-only checks only.

It can inspect:

- AWS caller identity
- AWS region
- ECS task metadata when running in ECS/Fargate
- CloudWatch metric visibility
- CloudWatch alarm summary
- CloudWatch log group retention summary
- Optional project resources when their environment variables are provided:
  - S3 report bucket
  - DynamoDB jobs table
  - SQS queue
  - SNS topic
  - EFS file system
  - ECS cluster

## Inputs

The skill reads context from environment variables.

Common runtime variables:

- `OPENCLAW_TASK_TYPE`
- `OPENCLAW_JOB_ID`
- `OPENCLAW_SELECTED_SKILL`
- `OPENCLAW_HOME`
- `OPENCLAW_CONFIG_PATH`
- `OPENCLAW_RUNTIME_DIR`
- `OPENCLAW_WORKSPACE`
- `OPENCLAW_PROMPT_PATH`
- `AWS_REGION`
- `AWS_DEFAULT_REGION`
- `DEEPSEEK_API_KEY`

Optional AWS resource variables:

- `S3_REPORT_BUCKET`
- `DYNAMODB_JOBS_TABLE`
- `SQS_QUEUE_URL`
- `SNS_TOPIC_ARN`
- `EFS_FILE_SYSTEM_ID`
- `ECS_CLUSTER_NAME`

Behavior variable:

- `OPENCLAW_DAILY_INSPECTION_STRICT`

When `OPENCLAW_DAILY_INSPECTION_STRICT=false`, only STS identity is treated as mandatory.

When `OPENCLAW_DAILY_INSPECTION_STRICT=true`, CloudWatch metric, alarm, and log group checks are also treated as mandatory.

## Output

The skill prints a JSON object to stdout.

Main fields:

- `task_type`
- `job_id`
- `selected_skill`
- `timestamp_utc`
- `aws_region`
- `environment`
- `checks`
- `permission_limitations`
- `warnings`
- `recommendations`
- `overall_ok`

## Exit Codes

- `0`: mandatory checks passed
- `1`: one or more mandatory checks failed

## Safety Rules

This skill must not:

- create AWS resources
- update AWS resources
- delete AWS resources
- stop AWS resources
- start AWS resources
- change CloudWatch alarms
- change log retention
- publish SNS messages
- consume or delete SQS messages
- print API keys, tokens, secrets, or temporary credentials

## AWS Permissions Needed

Minimum useful read-only permissions:

- `sts:GetCallerIdentity`
- `cloudwatch:ListMetrics`
- `cloudwatch:DescribeAlarms`
- `logs:DescribeLogGroups`

Optional read-only permissions when related resource variables are provided:

- `s3:HeadBucket`
- `dynamodb:DescribeTable`
- `sqs:GetQueueAttributes`
- `sns:GetTopicAttributes`
- `elasticfilesystem:DescribeFileSystems`
- `ecs:DescribeClusters`

## Notes

This skill is intentionally tolerant in non-strict mode. Some optional checks may fail during early deployment because Terraform resources, IAM permissions, or environment variables are not fully wired yet.

Permission failures are recorded under `permission_limitations` instead of being hidden.
