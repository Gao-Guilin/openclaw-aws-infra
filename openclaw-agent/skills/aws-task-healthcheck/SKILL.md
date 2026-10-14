# aws-task-healthcheck

## Purpose

`aws-task-healthcheck` verifies that the OpenClaw-AWS Agent container can start correctly and perform basic read-only AWS checks.

It is intended for the first ECS/Fargate RunTask validation and for later operational health checks.

## Scope

This skill performs only read-only checks.

It checks:

- OpenClaw runtime directory availability
- OpenClaw rendered configuration file validity
- Runtime workspace availability
- Prompt file availability
- OpenClaw CLI availability
- AWS region detection
- AWS STS caller identity
- Basic CloudWatch metric API visibility
- Presence or absence of required runtime secrets without printing secret values

## Inputs

The skill reads runtime context from environment variables.

Common variables:

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
- `OPENCLAW_REQUIRE_AWS`

## Output

The skill prints a JSON object to stdout.

Main fields:

- `task_type`
- `job_id`
- `selected_skill`
- `timestamp_utc`
- `aws_region`
- `checks`
- `warnings`
- `overall_ok`

## Exit Codes

- `0`: mandatory checks passed
- `1`: one or more mandatory checks failed

## Safety Rules

This skill must not:

- create AWS resources
- update AWS resources
- delete AWS resources
- stop or start AWS resources
- print API keys, tokens, secrets, or temporary credentials

## AWS Permissions Needed

Minimum read-only permissions for the first version:

- `sts:GetCallerIdentity`
- `cloudwatch:ListMetrics`

## Notes

`DEEPSEEK_API_KEY` is checked only for presence and length. The actual secret value is never printed.

When `OPENCLAW_REQUIRE_AWS=false`, AWS check failures are treated as warnings. This is useful for local container tests without AWS credentials.

For Fargate tests, keep `OPENCLAW_REQUIRE_AWS=true`.
