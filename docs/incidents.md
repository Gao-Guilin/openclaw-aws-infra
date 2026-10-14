# Incident & Troubleshooting Records

[中文](incidents.zh-CN.md)

## 1. Purpose of this document

This page summarizes selected troubleshooting records that are useful for reviewing the operational behavior of OpenClaw-AWS.

It is intentionally **not** a dump of private raw logs. Real account identifiers, full resource ARNs, Job IDs, screenshots, and private environment details are omitted. The goal is to preserve the failure mechanism, diagnostic path, recovery logic, and engineering lesson.

Two records are highlighted:

1. the 2026-08 Jobs lifecycle defect that left historical Jobs in `DISPATCHING`;
2. the 2026-10-12 controlled Dev fault-injection exercise covering runtime IAM, queue consumption, and terminal-state persistence.

## 2. Record A — Jobs stuck in DISPATCHING

**Type:** implementation defect / lifecycle gap
**Environment:** project runtime
**Discovery:** 2026-08-02
**Public record ID:** `OC-AWS-JOBS-001`

### Symptom

A review found multiple historical Jobs still recorded as:

```text
DISPATCHING
```

The corresponding Step Functions executions had succeeded, and container application logs existed, but the Jobs table did not reflect actual runtime completion.

### Initial boundary check

The investigation confirmed that:

- the receiver created the Job and marked dispatch state;
- Step Functions routed the work successfully;
- the task role already had the expected DynamoDB permissions;
- no relevant AccessDenied was found in the reviewed runtime path.

This ruled out a simple “missing DynamoDB permission” explanation for the original defect.

### Root cause

The lifecycle contract was incomplete.

The Job Receiver owned initial creation/dispatch state, and Step Functions owned queue delivery, but the container runtime did not yet write:

- `RUNNING` before workload execution;
- `SUCCEEDED` / `FAILED` after workload completion.

As a result:

```text
Step Functions success
≠ workload completion
```

and the Jobs record could remain at `DISPATCHING` even after real runtime activity.

### Fix

The Agent runtime added:

- a shared Jobs lifecycle helper;
- transition to `RUNNING` before the Skill starts;
- terminal `SUCCEEDED` / `FAILED` update after execution;
- best-effort failure persistence for preflight failures;
- terminal-state protection and idempotent repeated writes;
- bounded result metadata such as exit code, result status, result hash, and failure stage.

### Validation

The fix was validated against successful and controlled-failure paths. Terminal-state regression was blocked, and repeated writes of the same terminal result were accepted safely.

### Legacy boundary

The historical stale records were not retroactively marked successful because the original container exit evidence was no longer available.

This is an important evidence rule: **do not rewrite historical state with a result that can no longer be proven.**

### Lesson

A workflow-engine success signal is not the business completion signal. The same Job ID must connect ingress, routing, container execution, exit status, source result, and final lifecycle record.

## 3. Record B — 2026-10-12 Dev fault-injection exercise

**Type:** controlled fault injection / troubleshooting drill
**Environment:** Dev only
**Region:** `ap-northeast-1`
**Prod impact:** none

Three independent faults were injected at the same time, mapped to high, medium, and low priority work.

| Priority | Task | Symptom | Root cause |
| --- | --- | --- | --- |
| High | `healthcheck` | ECS task launched but container exited with code 1 | Explicit IAM deny on `cloudwatch:ListMetrics` |
| Medium | `daily_inspection` | Message stayed in SQS and no ECS task was launched | Corresponding EventBridge Pipe was `STOPPED` |
| Low | `cost_inspection` | Source check succeeded, but Jobs record did not reach terminal state | Explicit IAM deny on `dynamodb:UpdateItem` |

The purpose of the drill was not to demonstrate automatic remediation. It was to test whether failures at different layers could be separated using real service evidence.

## 4. High-priority case — runtime API denied

### Observed behavior

The high-priority healthcheck reached ECS and the container started, but it exited with code `1`.

Agent logs showed an AWS authorization failure for:

```text
cloudwatch:ListMetrics
```

The error explicitly stated that the action was blocked by an identity-based **explicit deny**.

### Diagnosis

The failing boundary was inside the running workload:

```text
ECS task launch        OK
Container startup      OK
CloudWatch API call    DENIED
Skill result           FAILED
```

The normal task policy already allowed the action; the injected explicit deny took precedence.

### Recovery rule

The correct recovery was to remove the injected deny and restore the known-good role state.

Adding another broad Allow would not override the explicit deny and would make the policy harder to reason about.

The already exited container was not expected to resume after IAM recovery. Validation therefore required a **new** healthcheck Job.

## 5. Medium-priority case — queue consumer stopped

### Observed behavior

The medium-priority job reached SQS, but no corresponding ECS task appeared.

The SQS metrics showed the following pattern:

```text
Sent = 1
Visible = 1
Received = 0
Deleted = 0
NotVisible = 0
AgeOfOldestMessage increasing
```

The corresponding EventBridge Pipe was `STOPPED`.

### Diagnosis

The boundary was isolated to:

```text
Step Functions → SQS       OK
SQS → EventBridge Pipe     blocked
Pipe → ECS                 not reached
```

This was not an ECS launch problem and not an upstream dispatch problem.

### Recovery rule

The message was left in SQS. No manual Receive/Delete was performed.

Restoring the Pipe to `RUNNING` allows the queued message to continue through the normal consumer path. An independent reversible drill on the same mechanism had already demonstrated backlog reduction and successful downstream execution after Pipe recovery.

That corroborating drill is kept conceptually separate from the exact 2026-10-12 evidence set.

## 6. Low-priority case — workload success, lifecycle persistence failure

### Observed behavior

The low-priority cost inspection completed its source work and reported:

```text
overall_ok = true
```

The ECS container exited normally, but the Jobs record did not reach the expected terminal state.

The lifecycle-write log showed an authorization failure for:

```text
dynamodb:UpdateItem
```

Again, the error identified an explicit deny.

### Diagnosis

The important distinction was:

```text
source workload result      SUCCEEDED
terminal state persistence  FAILED
```

This is a control-plane/data-plane consistency problem, not a source-inspection failure.

### Recovery rule

The injected deny was removed. Because the old container had already exited, recovery validation required a new Job to confirm that:

- the source workload still succeeds;
- `UpdateItem` is no longer denied;
- the Jobs record reaches `SUCCEEDED` or `FAILED` normally.

Repairing an old stale record should be done only after correlating its real ECS outcome; the project does not assume that every stale Job was successful.

## 7. Troubleshooting method used across the drill

The most reusable method was to split the architecture into boundaries and ask one question at a time:

```text
Was the request accepted?
→ Was the Job record created?
→ Did Step Functions dispatch?
→ Did SQS receive the message?
→ Did the Pipe consume it?
→ Did ECS start a task?
→ What was the container exit code?
→ What did the source Skill report?
→ Did the Jobs terminal state persist?
```

This avoids collapsing unrelated failures into a single explanation.

## 8. Evidence-first rules

Several evidence rules from the project are worth preserving:

- **Explicit Deny > Allow.** Do not “fix” an explicit deny by broadening Allow policies.
- **SQS metrics should be read as a set.** Sent alone does not prove consumption.
- **A queued message can continue after consumer recovery.** An already exited container cannot.
- **Source result and lifecycle state are different facts.** A successful workload can still have a stale control-plane record.
- **Restore the injected configuration to its previous known-good state.** Do not turn a fault drill into an unrelated redesign.
- **Do not claim unrecorded validation.** If a no-drift plan or recovery screenshot was not preserved, it should not be described as completed evidence.

## 9. Safety boundary of the fault exercise

The 2026-10-12 exercise was constrained to Dev.

The recovery plan explicitly avoided:

- deleting business data;
- deleting SQS, DynamoDB, EFS, or ECS resources;
- modifying Terraform state;
- using Terraform destroy/apply to create the fault;
- changing application source code as the first recovery action;
- affecting Prod.

The objective was diagnosis and reversible restoration, not destructive chaos testing.

## 10. What the incidents changed in the project

These records materially influenced the final design and documentation:

- Jobs lifecycle writes became a first-class runtime responsibility;
- terminal-state regression protection and idempotent updates were added;
- the project now explicitly documents `202 Accepted != task success` and `Step Functions success != Job success`;
- SQS/Pipe troubleshooting is treated as a separate layer from ECS runtime troubleshooting;
- runtime IAM failures are analyzed with attention to explicit deny semantics;
- the remaining need for an independent stale-job reconciliation mechanism is documented instead of hidden.

## 11. Remaining operational risk

The project still relies primarily on the ECS Agent to persist the final Job state.

An independent reconciliation service is not implemented. A production-oriented next step would be to periodically identify Jobs stuck in non-terminal states, correlate them with ECS task reality, and either perform bounded compensation or escalate them for operator review.

This limitation is intentionally retained in the public documentation because it is part of the actual engineering trade-off and failure model.
