# aws-alert-analysis

## Purpose

`aws-alert-analysis` normalizes and analyzes CloudWatch alarm events, SNS-wrapped alarm notifications, ECS task state-change events, and generic Agent failure payloads.

It separates:

- confirmed facts
- likely causes
- unknowns
- recommended next checks

It never performs remediation.

## Inputs

Common runtime variables:

- `OPENCLAW_TASK_TYPE`
- `OPENCLAW_JOB_ID`
- `OPENCLAW_SELECTED_SKILL`
- `AWS_REGION`
- `AWS_DEFAULT_REGION`

Primary input variables, evaluated in this order:

1. `OPENCLAW_ALERT_JSON`
2. `OPENCLAW_ALERT_FILE`
3. `OPENCLAW_EVENT_JSON`
4. fallback `OPENCLAW_ALERT_*` fields

Fallback fields:

- `OPENCLAW_ALERT_SOURCE`
- `OPENCLAW_ALERT_NAME`
- `OPENCLAW_ALARM_NAME`
- `OPENCLAW_ALARM_ARN`
- `OPENCLAW_ALERT_SEVERITY`
- `OPENCLAW_ALERT_STATE`
- `OPENCLAW_ALERT_MESSAGE`
- `OPENCLAW_LOG_GROUP_NAME`
- `OPENCLAW_LOG_STREAM_NAME`

Behavior controls:

- `OPENCLAW_ALERT_REQUIRE_PAYLOAD` — defaults to `true`
- `OPENCLAW_ALERT_ANALYSIS_STRICT` — defaults to `false`
- `OPENCLAW_ALERT_PERSIST_DYNAMODB` — defaults to `false`
- `OPENCLAW_ALERT_ID` — optional explicit idempotency key
- `DYNAMODB_ALERTS_TABLE` — required only when persistence is enabled

## Event normalization

The first version recognizes:

- EventBridge `CloudWatch Alarm State Change`
- classic CloudWatch alarm notifications, including SNS JSON envelopes
- EventBridge `ECS Task State Change`
- generic Agent failure payloads
- generic alert objects

The normalized event is used to create a deterministic `alert_id`. Re-running the same event with the same identity fields writes the same DynamoDB item when persistence is enabled.

## AWS reads

The skill can perform:

- `sts:GetCallerIdentity`
- `cloudwatch:DescribeAlarms`
- `logs:FilterLogEvents`
- `logs:GetLogEvents`

Read failures are reported in `checks`. They become task failures only when strict mode requires the failed check.

## Optional DynamoDB persistence

Persistence is opt-in:

```text
OPENCLAW_ALERT_PERSIST_DYNAMODB=true
DYNAMODB_ALERTS_TABLE=<alerts-table-name>
```

The record uses `alert_id` as the partition key and stores compact analysis metadata plus a sanitized JSON analysis document.

## Output contract

The skill prints one JSON object containing:

- `schema_version`
- `task_type`
- `job_id`
- `selected_skill`
- `status`
- `overall_ok`
- `timestamp_utc`
- `aws_region`
- `alert_id`
- `payload_sha256`
- `alert_source`
- `event_type`
- `event_id`
- `alert_name`
- `alert_state`
- `severity`
- `human_action_required`
- `summary`
- `checks`
- `confirmed_facts`
- `likely_causes`
- `unknowns`
- `recommended_next_checks`
- `permission_limitations`
- `warnings`
- `errors`
- `artifacts`

`status` is one of:

- `success`
- `partial_success`
- `failed`

## Exit codes

- `0` — the input contract and all requested operations succeeded
- `1` — input validation, strict checks, or requested persistence failed

## Safety rules

The skill must not:

- create, update, start, stop, or delete AWS infrastructure
- change alarms or log retention
- publish notifications
- consume queue messages
- auto-remediate
- print credentials, API keys, bearer tokens, or secret-like values

Both sensitive key names and common secret patterns inside strings are redacted before output or persistence.

The shared runtime entrypoint may archive an additional allowlisted, sanitized
result record to EFS after this skill exits. That archival is outside the
read-only alert-analysis contract and excludes the original alert payload.
