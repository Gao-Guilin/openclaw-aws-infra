# Changes & Architecture Decisions

[中文](changes-decisions.zh-CN.md)

## 1. Purpose

This document records selected engineering changes and architecture decisions that materially shaped OpenClaw-AWS.

It is not intended to reproduce every historical experiment. The focus is on decisions that are still visible in the current public source and that are useful for explaining trade-offs during code review or an interview.

## 2. Decision summary

| Decision | Current choice | Why it matters |
| --- | --- | --- |
| Runtime model | One-off ECS Fargate `RunTask` workloads | Avoids an always-on service for a low-concurrency project |
| Task routing | Step Functions → SQS priority queues → EventBridge Pipes | Separates ingress, buffering, routing, and execution |
| Environment separation | Independent `dev` and `prod` Terraform roots/state paths | Reduces accidental cross-environment changes |
| GitHub → AWS authentication | GitHub Actions OIDC with short-lived AWS credentials | Avoids stored long-lived AWS access keys |
| Production deployment | Separate Plan and Apply workflows | Makes the exact reviewed plan an approval boundary |
| Runtime IAM | Task Execution Role and Task Role are separate | Separates ECS startup permissions from application runtime permissions |
| Operational facts | Source Skills are authoritative | Prevents model-generated text from rewriting measured facts |
| Report generation | Deterministic report renderer with bounded LLM assistance | Keeps layout and factual fields controlled |
| ECS task definitions | `skip_destroy = true` | Retains old revisions and avoids deregistration during ordinary replacement |
| Schedulers | Disabled by default | Avoids unintended recurring execution and cost |

## 3. Runtime model: one-off Fargate tasks

### Decision

OpenClaw-AWS runs each operational job as an ECS Fargate one-off task instead of keeping an ECS Service permanently running.

### Rationale

The project is designed for a single-user, low-concurrency environment. Most workloads are inspections, alert analysis, or report generation rather than continuously served requests.

A one-off task model provides:

- process isolation per Job;
- direct mapping between a Job and a container run;
- no idle service that must remain continuously available;
- a simple scaling model for the expected workload.

### Trade-off

Cold-start and orchestration latency are accepted. This is not the right model for high-frequency interactive workloads.

## 4. Unified asynchronous job path

### Decision

Operator requests, scheduled jobs, and project alarms converge on the Job Receiver before entering the same lifecycle and routing path.

The normal path is:

```text
Ingress
→ Job Receiver
→ DynamoDB Jobs
→ Step Functions
→ SQS priority queue
→ EventBridge Pipe
→ ECS Fargate
→ Skill
→ terminal Job state / outputs
```

### Rationale

A unified path makes correlation and troubleshooting easier. The same Job identity can be followed from request acceptance through dispatch, queueing, execution, and terminal persistence.

### Lesson behind the decision

A historical lifecycle defect showed that successful workflow dispatch did not prove workload completion. The runtime therefore owns `RUNNING` and terminal state updates.

## 5. Priority queues and EventBridge Pipes

### Decision

Jobs are routed to separate `high`, `medium`, and `low` SQS queues. EventBridge Pipes consume the queues and start Fargate tasks.

### Rationale

This keeps buffering independent from container execution and makes queue health observable through native SQS metrics.

It also creates clear troubleshooting boundaries:

```text
Step Functions → SQS
SQS → Pipe
Pipe → ECS
ECS → Skill
```

### Trade-off

The three queues provide routing classes, not a strict global ordering guarantee across all priorities.

## 6. Dev and prod are separate Terraform roots

### Decision

`infra/envs/dev` and `infra/envs/prod` are maintained as separate root modules with separate state paths, naming prefixes, runtime secrets, and deployment controls.

### Rationale

The environments reuse modules but should not share mutable Terraform state.

This allows the project to keep common infrastructure code while preserving environment-specific safeguards.

### Trade-off

Some configuration is intentionally duplicated between root modules. The duplication is accepted in exchange for a clearer deployment boundary.

## 7. GitHub OIDC instead of long-lived AWS keys

### Decision

GitHub Actions assumes AWS roles through GitHub OIDC.

### Rationale

The deployment path should not depend on stored IAM user access keys.

The trust and IAM design scopes role assumption to expected repository/branch/environment identities, while deployment roles apply additional project and environment restrictions.

### Trade-off

OIDC does not eliminate IAM review. Some AWS create/list APIs cannot be perfectly constrained to resource ARNs, so trust conditions, naming/tagging rules, environment separation, reviewed plans, and explicit denies remain important controls.

## 8. Separate production Plan and Apply

### Decision

Production planning and production application are separate workflow stages.

The production Plan workflow:

- takes a previously validated image digest;
- promotes that exact artifact to the prod ECR repository;
- generates a saved Terraform plan;
- records plan metadata and SHA-256;
- publishes the plan as a reviewable workflow artifact.

The Apply workflow:

- requires a reviewed Plan run ID;
- validates the metadata;
- verifies the saved-plan checksum;
- checks out the source commit recorded by the plan;
- applies the exact reviewed plan;
- runs smoke validation and an immediate no-drift check.

### Rationale

The approval boundary is the exact plan artifact rather than a newly generated plan at apply time.

## 9. Source Skills own facts; the LLM owns presentation only

### Decision

Operational source Skills produce structured results. Report generation consumes a sanitized view of those results.

The model is limited to three presentation fields:

```json
{
  "executive_summary": "...",
  "risk_explanation": "...",
  "recommended_actions": ["..."]
}
```

It does not own:

- `overall_ok`;
- source `status`;
- `severity`;
- checks;
- confirmed facts;
- the final Markdown structure.

### Rationale

This prevents model interpretation from becoming the source of operational truth.

If the model call fails or returns invalid output, report generation falls back to a deterministic template.

## 10. Automatic report pipeline — 2026-10-13 change

### Change

The runtime was extended so the four operational source Skills can automatically invoke `aws-report-generation` after completing their source work.

The resulting pipeline is:

```text
source Skill
→ structured source JSON
→ sanitization
→ deterministic template or bounded LLM summary
→ fixed Chinese Markdown
→ compact summary JSON
→ optional S3 delivery
```

The source result file is never overwritten. Automatic report output uses a separate report-result file.

### Default behavior

```text
OPENCLAW_AUTO_REPORT_ENABLED=true
OPENCLAW_AUTO_REPORT_UPLOAD_S3=true
OPENCLAW_AUTO_REPORT_WRITE_INDEX=false
OPENCLAW_AUTO_REPORT_SUMMARY_MODE=auto
OPENCLAW_AUTO_REPORT_STRICT=false
```

### Design boundary

Report-generation failure does not normally turn a successful source Skill into a failed Job because `OPENCLAW_AUTO_REPORT_STRICT` defaults to `false`.

## 11. Retaining ECS task definition revisions

### Change

The ECS task definition resource currently uses:

```hcl
skip_destroy = true
```

### Rationale

During a Terraform migration, replacement of the managed task definition exposed a dependency on `ecs:DeregisterTaskDefinition`. Retaining old revisions avoids ordinary replacement requiring Terraform to deregister the previous revision.

### Trade-off

Old task-definition revisions accumulate and may require separate lifecycle management.

This setting is an intentional operational trade-off, not an assumption that old revisions should be retained forever.

## 12. Schedulers disabled by default

### Decision

The environment variable baseline keeps EventBridge Scheduler disabled unless explicitly enabled.

### Rationale

Scheduled inspections and reports are useful, but an always-enabled schedule would continuously create Jobs and AWS cost during a portfolio/demo lifecycle.

The default favors explicit activation over background activity.

## 13. Selected project evolution

The current implementation reflects several significant stages:

| Period | Change |
| --- | --- |
| 2026-07 | CI and remote Terraform state foundation |
| 2026-07 | GitHub OIDC / ECR delivery foundation |
| 2026-07 | Alert analysis and report Skills introduced |
| 2026-08 | Jobs lifecycle defect fixed and terminal-state protection added |
| 2026-08 | Dev/prod separation and deployment automation expanded |
| 2026-10-12 | Controlled Dev troubleshooting drill across IAM, SQS/Pipes, and lifecycle persistence |
| 2026-10-13 | Automatic report pipeline added and validated |
| 2026-10-13 | ECS task-definition retention behavior changed with `skip_destroy = true` |
| 2026-10-14 | Sanitized public repository published and public CI validated |

This timeline describes verifiable implementation milestones, not the date when the original project idea was first conceived.

## 14. Contribution and tooling boundary

The project owner drove requirements, scope, service selection, operational testing, troubleshooting, and acceptance decisions.

AI tools assisted with code generation, modification, review, and documentation. The public project should therefore be evaluated through:

- the implemented architecture;
- the ability to explain the design;
- operational troubleshooting evidence;
- validation results;
- engineering judgment and trade-offs;

rather than by claiming that every line was manually authored without assistance.
