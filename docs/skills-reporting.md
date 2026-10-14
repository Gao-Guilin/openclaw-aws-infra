# Skills & Report Pipeline

[中文](skills-reporting.zh-CN.md)

## 1. Skill model

OpenClaw-AWS does not expose an unrestricted shell or generic cloud-administration agent as its core interface. Runtime work is organized into a small set of predefined **CloudOps Skills** with explicit inputs, outputs, AWS calls, and safety boundaries.

The five current Skills are:

| Task type | Skill | Main responsibility |
| --- | --- | --- |
| `healthcheck` | `aws-task-healthcheck` | Verify runtime prerequisites, cloud identity, and basic CloudWatch visibility. |
| `daily_inspection` | `aws-daily-inspection` | Inspect project health, alarms, logs, and selected resources. |
| `cost_inspection` | `aws-cost-inspection` | Identify obvious cost and residual-resource risks. |
| `alert_analysis` | `aws-alert-analysis` | Normalize alert events and separate facts, likely causes, unknowns, and next checks. |
| `report_generation` | `aws-report-generation` | Convert sanitized structured results into human and machine-readable reports. |

## 2. Source Skills remain authoritative

The first four Skills are treated as **source Skills**. Their structured JSON result is the authoritative record of operational facts.

The report-generation layer is not allowed to change source fields such as:

- `overall_ok`;
- `status`;
- `severity`;
- `checks`;
- confirmed evidence.

This boundary is important because the LLM is used as a presentation helper, not as the source of truth for cloud state.

## 3. Healthcheck

`aws-task-healthcheck` validates whether the Agent container can run basic CloudOps work.

It checks items such as:

- runtime directories and rendered configuration;
- prompt/workspace availability;
- OpenClaw CLI presence;
- AWS region;
- STS caller identity;
- basic CloudWatch metric visibility;
- required secret presence without printing secret values.

Its core cloud actions are read-only. A mandatory-check failure returns a non-zero exit code.

## 4. Daily inspection

`aws-daily-inspection` performs lightweight read-only environment inspection.

It can inspect:

- caller identity and region;
- ECS task metadata;
- CloudWatch metric visibility and alarm summary;
- CloudWatch Logs retention summary;
- selected S3, DynamoDB, SQS, SNS, EFS, and ECS resources when their identifiers are provided.

Permission limitations are reported explicitly instead of being silently hidden. Strict mode can convert selected read failures into task failure; non-strict mode is more tolerant for partial environments.

## 5. Cost inspection

`aws-cost-inspection` looks for obvious cost or cleanup risks rather than calculating the final AWS bill.

Examples include:

- Cost Explorer / Budgets visibility;
- NAT Gateway presence;
- EFS presence and size;
- log groups without a retention policy;
- DynamoDB provisioned billing mode;
- SQS backlog;
- SNS topics with missing or pending subscriptions;
- ECS cluster task/service counts.

The Skill records `cost_risks`, permission limitations, and recommendations while keeping infrastructure changes out of scope.

## 6. Alert analysis

`aws-alert-analysis` accepts multiple event shapes, including:

- EventBridge CloudWatch Alarm State Change events;
- classic CloudWatch alarm notifications, including SNS-wrapped payloads;
- ECS task state-change events;
- generic Agent failure payloads;
- generic alert objects.

Its output deliberately separates:

```text
confirmed_facts
likely_causes
unknowns
recommended_next_checks
```

`likely_causes` are hypotheses, not confirmed root causes. The Skill does not remediate infrastructure.

## 7. Unified report pipeline

The normal automatic report flow is:

```text
source Skill
  → structured source JSON
  → sanitization
  → summary routing
       → deterministic template
       OR
       → bounded OpenClaw + DeepSeek interpretation
  → fixed Markdown renderer
  → summary JSON
  → optional S3 upload
  → optional DynamoDB Reports index
```

The source result file is kept separate from the report result. Automatic reporting writes its own result under:

```text
/tmp/openclaw-report-results/<job-id>.json
```

## 8. Bounded LLM responsibility

When LLM-assisted summarization is used, the model is allowed to return only three presentation fields:

```json
{
  "executive_summary": "...",
  "risk_explanation": "...",
  "recommended_actions": ["...", "..."]
}
```

The model prompt explicitly prohibits it from:

- calling tools;
- reading additional files;
- accessing AWS;
- executing commands;
- changing source `overall_ok`, `status`, `severity`, `checks`, or confirmed facts;
- turning `likely_causes` into confirmed root cause;
- inventing missing evidence;
- recommending automatic infrastructure changes.

If model execution or output validation fails, report generation falls back to the deterministic template.

## 9. Routing policy

With `OPENCLAW_REPORT_SUMMARY_MODE=auto`, the report layer chooses between template, Flash, and Pro based on the source result.

The current policy is broadly:

| Source | Clean/simple result | Warning / ordinary issue | Higher-complexity / higher-severity result |
| --- | --- | --- | --- |
| Healthcheck | Template | Flash | Flash |
| Daily inspection | Template | Flash | Flash |
| Cost inspection | Template | Flash | Pro for multi-risk/complex cases |
| Alert analysis | Template for simple info/low | Flash for medium | Pro for high/critical |
| EFS aggregate report | — | — | Pro |

Manual override values are:

```text
template
llm_flash
llm_pro
auto
```

## 10. Sanitization boundary

Before model input and report delivery, the pipeline applies an allowlisted/sanitized view of the source result.

The summarizer receives only fields needed to explain the operational result. Sensitive key names and common secret-like string patterns are redacted before rendering, model input, storage, and stdout where supported by the report pipeline.

The original alert payload is not blindly copied into the EFS history path.

## 11. Deterministic Markdown structure

The final human-readable report uses a fixed Simplified Chinese structure:

1. 检查结论
2. 本次检查内容
3. 检查结果
4. 发现的问题、警告与限制
5. 风险说明
6. 建议
7. 任务信息
8. 结构化证据摘要

The LLM does not own this layout. This keeps report shape stable across template and LLM-assisted modes.

## 12. Report artifacts

The report layer produces two main artifact types:

```text
<source-skill>_<YYYYMMDDTHHMMSSZ>_<job-id>.md
<source-skill>_<YYYYMMDDTHHMMSSZ>_<job-id>.summary.json
```

When S3 upload is enabled, the current layout is:

```text
reports/<environment>/<source-skill>/<YYYY>/<MM>/<DD>/
```

The Markdown file is for human review. The `.summary.json` file provides a compact machine-readable result for later indexing or automation.

## 13. Optional DynamoDB Reports index

Report indexing is available but disabled by default for the automatic post-task path.

When enabled, the Reports table can store metadata such as:

- report/job identity;
- source task and Skill;
- source health result;
- report status;
- selected summary mode/model;
- counts and hashes;
- S3 artifact locations.

This keeps large human-readable content in S3 while preserving queryable report metadata separately.

## 14. EFS history aggregation

The runtime can store sanitized short-term task history on EFS. `aws-report-generation` can aggregate recent history when explicit report input is not supplied.

Important bounds include:

- allowlisted task types;
- retention window;
- per-file maximum size;
- lookback window;
- maximum number of history records consumed by one report.

The public baseline uses a bounded lookback and item count rather than treating EFS as an unlimited long-term analytics database.

## 15. Automatic-report defaults

The current runtime defaults are:

```text
OPENCLAW_AUTO_REPORT_ENABLED=true
OPENCLAW_AUTO_REPORT_UPLOAD_S3=true
OPENCLAW_AUTO_REPORT_WRITE_INDEX=false
OPENCLAW_AUTO_REPORT_SUMMARY_MODE=auto
OPENCLAW_AUTO_REPORT_STRICT=false
OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS=120
```

The non-strict default is deliberate: a presentation-layer failure should not automatically rewrite the outcome of an otherwise successful source Skill.

## 16. Failure semantics

The report pipeline keeps several outcomes distinct:

- source Skill failure;
- LLM summary failure;
- Markdown/summary generation failure;
- S3 delivery failure;
- optional Reports-index failure.

An LLM failure triggers deterministic fallback. A report delivery problem is recorded as a report-pipeline issue. If strict automatic reporting is disabled, it does not replace a successful source result with a false source failure.

## 17. Why this design matters

The project originally needed human-readable operational output, but allowing a free-form model to rewrite system facts would weaken auditability.

The final design therefore uses a hybrid model:

```text
deterministic code owns facts and evidence
+ bounded LLM owns explanation and wording
+ deterministic renderer owns report structure
```

This allows the project to demonstrate LLM integration without making operational truth depend on unconstrained model output.

## 18. Current boundaries

The Skills/report system does not claim:

- autonomous infrastructure remediation;
- unrestricted shell execution as an operator feature;
- that every permission limitation is automatically resolvable;
- that model recommendations are authoritative change instructions;
- that EFS history is a permanent evidence archive;
- that the LLM can override missing evidence or promote hypotheses into facts.
