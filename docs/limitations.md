# Limitations & Known Constraints

[中文](limitations.zh-CN.md)

## 1. Why this document exists

OpenClaw-AWS is a portfolio project and a working CloudOps prototype, not an enterprise product.

This document makes the current boundaries explicit so that the repository can be reviewed without inflating the implementation beyond what the source and evidence support.

## 2. Intended operating scale

The current design targets:

- a single project owner/operator;
- low request frequency;
- low concurrency;
- bounded AWS scope;
- predefined operational task types.

It has not been designed or load-tested as a high-throughput multi-tenant service.

## 3. No autonomous remediation

The current Skills inspect, analyze, record, report, and notify.

They do **not** provide unrestricted automatic remediation such as:

- deleting resources;
- changing IAM;
- restarting arbitrary services;
- scaling arbitrary workloads;
- applying Terraform automatically in response to an alarm.

Recommended actions in reports are guidance for an operator, not self-executing remediation commands.

## 4. Networking is cost-oriented, not private-subnet-only

The current baseline uses public subnets for Fargate tasks and assigns public IP addresses.

The project does not create a NAT Gateway.

This was a deliberate cost/complexity trade-off for a low-concurrency personal environment.

It should not be presented as a hardened private-subnet production network.

## 5. One-off Fargate execution has latency

Each Job launches an ECS Fargate task.

Benefits include isolation and reduced idle runtime, but the model introduces startup and orchestration latency.

It is not optimized for sub-second interactive execution.

## 6. Priority queues do not provide strict global ordering

The `high`, `medium`, and `low` SQS queues represent routing classes.

The architecture does not guarantee strict total ordering across all queues or all Jobs.

## 7. Job terminal-state reconciliation is not independent

The ECS Agent normally persists `RUNNING` and terminal state.

If a task is terminated before the Agent can persist the terminal update, a stale Job can remain.

The current project does not include a separate reconciliation service that continuously compares ECS task outcomes with Jobs table state and repairs inconsistencies.

This limitation was one of the lessons reinforced by lifecycle troubleshooting.

## 8. Some auxiliary failures are non-strict by default

The runtime can treat supporting operations as best effort depending on configuration.

Examples include:

- EFS history archival;
- automatic report generation;
- SNS notification.

A successful source Skill may remain a successful Job when a non-strict auxiliary step fails.

This behavior prevents presentation/delivery failures from automatically rewriting source execution truth, but operators must read warnings and report-delivery status separately.

## 9. LLM assistance is bounded but still non-deterministic

The report pipeline deliberately restricts model responsibility.

The LLM cannot overwrite source facts and must return a small JSON structure, but natural-language wording is still non-deterministic.

The deterministic template fallback exists for this reason.

LLM output should never be treated as the sole source of confirmed root cause.

## 10. Reports are currently rendered in Simplified Chinese

The fixed operational Markdown report structure is currently Simplified Chinese.

This repository documentation is bilingual, but the runtime report renderer itself is not a bilingual report system.

## 11. Scheduler is disabled by default

Scheduled inspections and weekly reports exist in the architecture, but the default environment configuration keeps Scheduler disabled.

This prevents unintentional recurring Jobs and cost in a demo/portfolio environment.

It also means scheduled behavior must be explicitly enabled and validated when required.

## 12. Public deployment workflows are templates

The public repository stores deployment workflows under:

```text
.github/deployment-templates/
```

They are intentionally not active GitHub Actions workflows.

The templates contain sanitized account placeholders and must not be enabled without:

- replacing environment-specific placeholders;
- creating the required OIDC/IAM roles;
- configuring Terraform state;
- provisioning secrets;
- reviewing the workflow trust and environment controls.

The public snapshot is not an immediately deployable production configuration by itself.

## 13. Fresh-account reproducibility has a boundary

The Terraform and deployment documentation describe a source-derived bootstrap order.

The project was built and validated in its original AWS environment, but the sanitized public snapshot has not been independently proven by performing a complete zero-to-production deployment in a separate clean AWS account.

That distinction is intentionally preserved.

## 14. Historical evidence is not a live health guarantee

Historical cloud validation demonstrates that specific paths worked at the time they were tested.

It does not prove:

- that the original AWS environment still exists unchanged;
- that every dependency remains healthy;
- that there is no later drift.

Current public CI is evidence about the repository snapshot, not a live-cloud uptime check.

## 15. ECS task-definition revisions accumulate

The ECS task definition uses:

```hcl
skip_destroy = true
```

This avoids automatic deregistration during ordinary replacement and reduces deployment-role requirements.

The trade-off is that historical revisions accumulate.

The current project does not implement an automated task-definition revision retention/cleanup policy.

## 16. QQBot is reserved, not a validated primary path

The Agent retains QQBot-related configuration hooks, but QQBot is disabled by default and should not be presented as a validated primary ingress channel.

The implemented portfolio focus is operator/API input, alarm ingestion, scheduled jobs, and CloudOps Skills.

## 17. EFS history is a bounded operational history store

EFS is used for sanitized, bounded task history and report aggregation.

It is not intended to act as:

- an immutable audit ledger;
- a long-term analytics warehouse;
- a compliance archive.

Retention and file-size limits are deliberately configurable.

## 18. Budget controls are visibility, not a hard spending cap

AWS Budgets can provide cost visibility and notifications.

A budget threshold does not stop AWS services from generating charges.

Cost control still depends on architecture, schedules, cleanup, and operator discipline.

## 19. Public sanitization cannot replace secret-management discipline

The repository includes CI checks for common secret signatures and excludes known private artifact classes.

However:

- regex-based scanning is not mathematically complete;
- future contributors can still accidentally add sensitive material;
- deployment should continue to use Secrets Manager, OIDC, private variable files, and environment controls.

Publication scanning is a guardrail, not the secret-management system.

## 20. Scope not claimed

The current project does not claim:

- enterprise SRE maturity;
- automatic incident remediation;
- multi-region high availability;
- multi-tenant isolation;
- Kubernetes orchestration;
- formal compliance certification;
- complete disaster recovery;
- high-concurrency performance validation.

These are outside the current portfolio scope rather than hidden implementation gaps.

## 21. Recommended next improvements

If the project were continued beyond portfolio closure, the highest-value engineering improvements would be:

1. independent Job-state reconciliation;
2. fresh-account deployment rehearsal from the public documentation;
3. automated retention for old ECS task-definition revisions;
4. stronger end-to-end evidence packaging;
5. additional integration tests for real AWS failure boundaries;
6. optional bilingual runtime report rendering.

These are future improvements, not requirements for understanding the current implementation.
