# Operations & Job Lifecycle

[中文](operations-lifecycle.zh-CN.md)

## 1. Operational model

OpenClaw-AWS treats each request as an asynchronous Job that moves through a visible lifecycle. Operator requests, scheduled jobs, and project monitoring alarms are normalized into the same ingress path before routing and execution.

The main operational chain is:

```text
API / CloudWatch Alarm / Scheduler
  → Job Receiver Lambda
  → DynamoDB Jobs
  → Step Functions
  → SQS high / medium / low
  → EventBridge Pipes
  → ECS Fargate RunTask
  → Skill execution
  → lifecycle / history / report / notification handling
```

The design deliberately distinguishes **request acceptance**, **routing success**, **container execution**, and **final business outcome**.

## 2. Unified ingress

The Job Receiver accepts three event families:

- API Gateway requests from the operator-facing API;
- EventBridge Scheduler envelopes;
- CloudWatch Alarm state-change events routed through EventBridge.

The receiver normalizes them into a common internal structure containing fields such as:

- `job_id`;
- `task_type`;
- `priority`;
- `target`;
- source metadata;
- request timestamp;
- optional alert payload.

Supported task types are:

```text
healthcheck
daily_inspection
cost_inspection
alert_analysis
report_generation
```

Supported priorities are `high`, `medium`, and `low`. The current target is `aws-account`.

## 3. Job creation and dispatch

A newly accepted job is first written to DynamoDB with:

```text
status = RECEIVED
```

The receiver then starts the Step Functions workflow. If the start succeeds, the Jobs record advances to:

```text
DISPATCHING
```

If starting the workflow fails, the receiver attempts to mark the Job as:

```text
START_FAILED
```

The API's asynchronous response therefore represents acceptance/dispatch state, not workload completion.

## 4. Deduplication behavior

Scheduled jobs and CloudWatch alarm events derive a deterministic deduplication key. The receiver uses that key to produce a stable Job identity for repeat delivery of the same logical event.

If a duplicate event is detected after the job has already moved beyond the initial pre-dispatch states, the receiver returns the existing Job state instead of starting a second workflow.

If a previous attempt created the record but did not successfully dispatch it, the receiver can retry the dispatch path.

This is useful because event-driven systems must assume that delivery and retries can happen more than once.

## 5. Priority routing

Step Functions routes jobs to one of three SQS queues:

- high;
- medium;
- low.

The queues decouple ingestion from execution and preserve work while downstream execution is temporarily unavailable.

Each queue is connected to ECS through an EventBridge Pipe. The project uses one message per task launch, so a queued job becomes a one-off Fargate task.

The three queues are priority lanes, not a strict global ordering mechanism. A low-priority task may finish before a high-priority task depending on queue state, launch timing, and runtime duration.

## 6. ECS runtime start

The container starts through `openclaw-agent/entrypoint.sh`.

Before Skill execution, the entrypoint:

- prepares the runtime directories;
- renders the OpenClaw configuration;
- validates required runtime prerequisites;
- resolves `OPENCLAW_TASK_TYPE` to the corresponding Skill;
- checks that the Skill runner exists and is executable;
- attempts to update the Jobs record to `RUNNING`.

The normal lifecycle therefore becomes:

```text
RECEIVED → DISPATCHING → RUNNING → SUCCEEDED / FAILED
```

## 7. Lifecycle persistence

The shared `job_status_store.py` module is responsible for the ECS-side lifecycle writes.

It implements several protections:

- `RUNNING` is written only from non-terminal states;
- a terminal `SUCCEEDED` or `FAILED` state is not allowed to regress back to `RUNNING`;
- writing the same requested terminal state again is treated idempotently;
- the final record can include exit code, completion timestamps, result hash, source result status, `overall_ok`, failure stage, and bounded error text.

Conditional DynamoDB updates are used so conflicting state transitions do not silently overwrite a terminal record.

## 8. Source result vs. lifecycle state

The project intentionally keeps two concepts separate:

- **source result** — what the Skill actually observed or concluded;
- **Job lifecycle state** — whether the orchestration/runtime pipeline completed and persisted the Job outcome.

For example, an inspection may produce `overall_ok=true`, but if the Agent cannot write the terminal DynamoDB update, the control-plane record may remain stale.

This distinction became important during fault-injection testing and is one of the main operational lessons of the project.

## 9. Post-Skill handling

After the source Skill returns, the entrypoint can perform several follow-up stages.

### EFS sanitized history

Selected result data can be sanitized and archived to EFS. The history layer is used for bounded report aggregation rather than for retaining raw source payloads indefinitely.

### Automatic reporting

For the four operational source Skills, the Agent can automatically invoke `aws-report-generation` using a separate report-result file. The source result is never overwritten.

### SNS notification

A shared notification dispatcher may publish a post-task SNS notification when notification is enabled.

### Terminal lifecycle write

The entrypoint computes the final exit code and attempts to persist `SUCCEEDED` or `FAILED` into the Jobs table.

## 10. Strict vs. best-effort follow-up stages

The runtime distinguishes the source workload from follow-up delivery concerns.

Important controls include:

- `OPENCLAW_JOB_STATUS_STRICT`;
- `OPENCLAW_EFS_HISTORY_STRICT`;
- `OPENCLAW_AUTO_REPORT_STRICT`;
- `OPENCLAW_SNS_NOTIFY_STRICT`.

In the default public baseline, report generation is non-strict. A report-generation failure does not automatically turn an otherwise successful source Skill into a failed Job.

This prevents a presentation-layer failure from being confused with a source inspection failure, while still preserving report-pipeline errors in its own result.

## 11. Completion semantics

Three operational statements should not be conflated:

```text
HTTP 202 Accepted
≠ Step Functions success
≠ final Job success
```

- `202 Accepted` means the system accepted the asynchronous request.
- Step Functions success means validation/routing reached the queue as designed.
- Final success requires the ECS workload to run and the lifecycle record to reach the intended terminal state.

For troubleshooting, the final decision should correlate:

- Job record;
- Step Functions execution;
- SQS/Pipe state;
- ECS task state and container exit code;
- CloudWatch logs;
- source result file / report evidence where applicable.

## 12. Queue troubleshooting signals

A useful SQS diagnosis combines multiple metrics rather than looking at only one:

```text
NumberOfMessagesSent
NumberOfMessagesReceived
NumberOfMessagesDeleted
ApproximateNumberOfMessagesVisible
ApproximateNumberOfMessagesNotVisible
ApproximateAgeOfOldestMessage
```

For example, a message that remains visible while `Received=0`, `Deleted=0`, and age keeps rising strongly suggests the queue received the work but the consumer path is not taking it.

That signal was used to isolate a stopped EventBridge Pipe during a Dev fault-injection exercise.

## 13. Operational evidence by layer

| Layer | Useful evidence |
| --- | --- |
| API ingress | API response, request ID, authorizer/receiver logs |
| Job control plane | DynamoDB Jobs state and timestamps |
| Workflow | Step Functions execution status and input/output |
| Queue | SQS backlog, receive/delete counts, message age |
| Queue consumer | EventBridge Pipe state and Pipe logs |
| Runtime | ECS task status, stop reason, container exit code |
| Application | Skill JSON result and CloudWatch Agent logs |
| Delivery | EFS history, S3 report artifacts, Reports table, SNS outcome |

The most reliable troubleshooting method is to locate the last confirmed-good boundary, then move one hop downstream.

## 14. Known lifecycle limitation

The final Job state is still primarily written by the ECS Agent itself.

If the container exits after doing useful work but cannot persist its terminal state, the Jobs table can become stale. Likewise, a container that is terminated externally before finalization cannot rely on its own code to repair the record.

The current project does **not** include an independent reconciliation controller that periodically compares ECS task reality with long-running `DISPATCHING` / `RUNNING` Jobs.

A future production-oriented design could add a reconciliation path that identifies stale records, correlates ECS state, and performs bounded compensation or operator escalation.

## 15. Operational runbook summary

When a Job appears stuck or inconsistent:

1. identify the Job and current lifecycle state;
2. confirm whether Step Functions actually dispatched it;
3. inspect the corresponding SQS queue and EventBridge Pipe;
4. confirm whether an ECS task was launched;
5. inspect container exit code and Agent logs;
6. compare the source result with the Jobs terminal state;
7. check for IAM `AccessDenied`, especially explicit deny text;
8. restore the known-good configuration rather than broadening permissions blindly;
9. submit a new test Job when the old container has already exited;
10. preserve evidence and avoid rewriting historical outcomes that can no longer be proven.
