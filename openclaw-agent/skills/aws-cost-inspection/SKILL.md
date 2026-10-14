# aws-cost-inspection

## Purpose

`aws-cost-inspection` performs a read-only cost risk inspection for the OpenClaw-AWS project.

It is designed to help identify obvious AWS cost risks during deployment, testing, demo, and post-demo cleanup.

## Scope

This skill performs read-only checks only.

It can inspect:

- AWS caller identity
- Cost Explorer usage summary
- AWS Budgets summary
- CloudWatch Logs storage and retention risk
- NAT Gateway presence
- EFS file system presence and size
- ECS cluster task/service counts
- DynamoDB table billing mode
- SQS queue message backlog
- SNS topic subscription state

## Inputs

The skill reads runtime context from environment variables.

Common runtime variables:

- `OPENCLAW_TASK_TYPE`
- `OPENCLAW_JOB_ID`
- `OPENCLAW_SELECTED_SKILL`
- `AWS_REGION`
- `AWS_DEFAULT_REGION`

Optional project resource variables:

- `ECS_CLUSTER_NAME`
- `DYNAMODB_JOBS_TABLE`
- `SQS_QUEUE_URL`
- `SNS_TOPIC_ARN`

Behavior variable:

- `OPENCLAW_COST_INSPECTION_STRICT`

When `OPENCLAW_COST_INSPECTION_STRICT=false`, only STS identity is mandatory.

When `OPENCLAW_COST_INSPECTION_STRICT=true`, the skill also treats Cost Explorer, Budgets, CloudWatch Logs, NAT Gateway, and EFS checks as mandatory.

## Output

The skill prints a JSON object to stdout.

Main fields:

- `task_type`
- `job_id`
- `selected_skill`
- `timestamp_utc`
- `aws_region`
- `checks`
- `cost_risks`
- `permission_limitations`
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
- change budgets
- change CloudWatch log retention
- publish SNS messages
- consume or delete SQS messages
- print API keys, tokens, secrets, or temporary credentials

## AWS Permissions Needed

Minimum permission:

- `sts:GetCallerIdentity`

Useful cost-read permissions:

- `ce:GetCostAndUsage`
- `budgets:DescribeBudgets`
- `logs:DescribeLogGroups`
- `ec2:DescribeNatGateways`
- `elasticfilesystem:DescribeFileSystems`
- `ecs:DescribeClusters`
- `dynamodb:DescribeTable`
- `sqs:GetQueueAttributes`
- `sns:GetTopicAttributes`

## Cost Risk Rules

The first version highlights:

- active or pending NAT Gateway
- EFS file systems that exist during MVP/demo
- CloudWatch log groups without retention policy
- DynamoDB table using provisioned capacity
- SQS messages pending or in flight
- SNS topic with no confirmed subscriptions or pending subscriptions

## Notes

Cost Explorer and Budgets checks may fail if billing permissions are not granted to the task role. Such failures are reported under `permission_limitations` and do not fail the task unless strict mode is enabled.

This skill does not calculate exact final bills. It provides early cost-risk visibility for the OpenClaw-AWS deployment.
