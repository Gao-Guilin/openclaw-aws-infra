# aws-report-generation

## Purpose

`aws-report-generation` is the unified presentation and delivery layer for OpenClaw-AWS operational results.

It accepts sanitized output from:

- `aws-task-healthcheck`
- `aws-daily-inspection`
- `aws-cost-inspection`
- `aws-alert-analysis`
- bounded EFS history aggregation

It converts the source result into:

- a fixed-structure Simplified Chinese Markdown report for humans
- a compact JSON summary for machines
- optional S3 artifacts
- an optional DynamoDB report index

The source skill remains authoritative for operational facts. Report generation must not change the source `overall_ok`, `status`, `severity`, `checks`, or confirmed evidence.

## Processing model

The normal post-task flow is:

```text
source skill
  -> structured source JSON
  -> sanitization
  -> report routing
       -> deterministic Chinese template, or
       -> bounded OpenClaw + DeepSeek summary
  -> fixed Markdown renderer
  -> JSON summary
  -> optional S3 upload
  -> optional DynamoDB Reports index
```

The LLM never owns the Markdown layout. It can only provide:

- `executive_summary`
- `risk_explanation`
- `recommended_actions`

If the model call fails, report generation falls back to the deterministic Chinese template.

## Routing policy

Default `OPENCLAW_REPORT_SUMMARY_MODE=auto`:

- Healthcheck: clean success -> template; warning/failure -> DeepSeek Flash
- Daily inspection: clean success -> template; warning/permission/failure -> DeepSeek Flash
- Cost inspection: no risk -> template; ordinary risks -> Flash; multi-risk/complex result -> Pro
- Alert analysis: info/low simple result -> template; medium -> Flash; high/critical -> Pro
- EFS aggregate report -> Pro

Manual override values:

- `template`
- `llm_flash`
- `llm_pro`
- `auto`

## Inputs

Common variables:

- `OPENCLAW_TASK_TYPE`
- `OPENCLAW_JOB_ID`
- `OPENCLAW_SELECTED_SKILL`
- `AWS_REGION`
- `AWS_DEFAULT_REGION`
- `OPENCLAW_RUNTIME_DIR`
- `OPENCLAW_REPORT_DIR`
- `OPENCLAW_ENVIRONMENT`

Source variables:

- `OPENCLAW_REPORT_INPUT_JSON`
- `OPENCLAW_REPORT_INPUT_FILE`
- `OPENCLAW_SOURCE_TASK_TYPE`
- `OPENCLAW_SOURCE_SKILL`
- `OPENCLAW_REPORT_TITLE`

Model variables:

- `DEEPSEEK_API_KEY`
- `OPENCLAW_CONFIG_PATH`
- `OPENCLAW_WORKSPACE`
- `OPENCLAW_REPORT_PROMPT_PATH`
- `OPENCLAW_REPORT_SUMMARY_MODE`
- `OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS`

Behavior controls:

- `OPENCLAW_REPORT_REQUIRE_INPUT` — defaults to `true`
- `OPENCLAW_REPORT_UPLOAD_S3` — defaults to `false` for standalone report tasks
- `OPENCLAW_REPORT_WRITE_INDEX` — defaults to `false`
- `OPENCLAW_REPORT_ID` — optional deterministic report id override
- `OPENCLAW_REPORT_EFS_AGGREGATE` — defaults to `true`
- `OPENCLAW_EFS_HISTORY_DIR` — defaults to `/app/runtime/history`
- `OPENCLAW_EFS_HISTORY_TASK_TYPES`
- `OPENCLAW_REPORT_EFS_LOOKBACK_HOURS` — defaults to `168`
- `OPENCLAW_REPORT_EFS_MAX_ITEMS` — defaults to `100`
- `OPENCLAW_EFS_HISTORY_MAX_FILE_BYTES` — defaults to `262144`

## Automatic post-task reporting

`entrypoint.sh` automatically invokes this skill after the four operational source skills when:

```text
OPENCLAW_AUTO_REPORT_ENABLED=true
```

Default automatic behavior:

```text
OPENCLAW_AUTO_REPORT_ENABLED=true
OPENCLAW_AUTO_REPORT_UPLOAD_S3=true
OPENCLAW_AUTO_REPORT_WRITE_INDEX=false
OPENCLAW_AUTO_REPORT_SUMMARY_MODE=auto
OPENCLAW_AUTO_REPORT_STRICT=false
```

The source result file is never overwritten. Automatic reporting uses a separate report-result file under `/tmp/openclaw-report-results/`.

## Chinese Markdown structure

The report structure is deterministic:

1. 检查结论
2. 本次检查内容
3. 检查结果
4. 发现的问题、警告与限制
5. 风险说明
6. 建议
7. 任务信息
8. 结构化证据摘要

The report is written in Simplified Chinese. AWS names, resource IDs, error codes, and field names may remain in English.

## Artifact naming

The source task timestamp is used whenever available.

```text
<source-skill>_<YYYYMMDDTHHMMSSZ>_<job-id>.md
<source-skill>_<YYYYMMDDTHHMMSSZ>_<job-id>.summary.json
```

Example:

```text
aws-task-healthcheck_20261013T031522Z_1234abcd.md
```

## Local artifacts

Default directory:

```text
/app/runtime/reports
```

Because `/app/runtime` is the ECS EFS mount in the current deployment, these local artifacts may also persist on EFS.

## S3 layout

When S3 upload is enabled:

```text
reports/<environment>/<source-skill>/<YYYY>/<MM>/<DD>/<source-skill>_<timestamp>_<job-id>.md
reports/<environment>/<source-skill>/<YYYY>/<MM>/<DD>/<source-skill>_<timestamp>_<job-id>.summary.json
```

Example:

```text
reports/dev/aws-task-healthcheck/2026/10/13/aws-task-healthcheck_20261013T031522Z_1234abcd.md
```

S3 variables:

- `S3_REPORT_BUCKET`
- `S3_REPORT_PREFIX` — defaults to `reports`

## Optional DynamoDB report index

Enable explicitly:

```text
OPENCLAW_REPORT_WRITE_INDEX=true
DYNAMODB_REPORTS_TABLE=<reports-table-name>
```

The index stores report/job identity, source skill/task, source health result, report status, summary mode/model, counts, hashes, and S3 locations.

## Failure semantics

Source execution and report delivery are separate concerns.

- A source Skill success is not changed to source failure because an LLM call fails.
- LLM failure -> deterministic template fallback.
- S3 failure -> report result records delivery failure.
- `OPENCLAW_AUTO_REPORT_STRICT=false` means a report-generation failure does not change a successful source Job into FAILED.
- `OPENCLAW_AUTO_REPORT_STRICT=true` may promote report-generation failure to the final Job failure state when the source Skill itself succeeded.
- If the source Skill already failed, its failure remains the primary failure.

## Output summary contract

The skill prints one JSON object containing fields including:

- `schema_version`
- `task_type`
- `job_id`
- `status`
- `overall_ok` — report pipeline health, not source health
- `source_overall_ok`
- `source_task_type`
- `source_skill`
- `environment`
- `report_id`
- `artifact_basename`
- `report_status`
- `summary_mode`
- `model_used`
- `executive_summary`
- `risk_explanation`
- warning/failure/cost/recommendation counts
- `markdown_sha256`
- `errors`
- `artifacts`

## Safety rules

This skill must not:

- modify infrastructure
- perform remediation
- alter source result facts
- expose secret values
- treat model inference as confirmed evidence
- treat `likely_causes` as confirmed root cause

Sensitive keys and common secret patterns are redacted before rendering, model input, storage, and stdout output.
