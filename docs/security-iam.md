# Security & IAM Design

[中文](security-iam.zh-CN.md)

## 1. Security objective

OpenClaw-AWS is designed as a single-user, low-concurrency CloudOps/AIOps prototype. Its security model focuses on **narrow trust boundaries, short-lived credentials, role separation, secret isolation, and auditable execution** rather than on providing a general-purpose administrative agent.

The core rule is simple: the system may inspect and report on AWS resources through predefined workflows, while infrastructure-changing permissions remain confined to explicitly controlled deployment paths.

## 2. Trust boundaries

The project separates the main trust domains instead of using one broad AWS identity for everything.

| Boundary | Identity / control | Primary responsibility |
| --- | --- | --- |
| Operator API | API Gateway + Lambda Authorizer | Authenticate operator-triggered requests. |
| Job ingestion | Job Receiver Lambda role | Validate jobs, write lifecycle records, start Step Functions. |
| Workflow routing | Step Functions role | Route jobs and send them to priority queues. |
| Queue-to-runtime bridge | EventBridge Pipes role | Consume SQS messages and launch the approved ECS task definition. |
| Scheduled ingress | EventBridge Scheduler role | Invoke the unified Job Receiver for approved schedules. |
| Container startup | ECS Task Execution Role | Pull images, retrieve runtime secrets, and write startup/runtime logs. |
| Container workload | ECS Task Role | Perform the AWS reads and limited project-state writes needed by Skills. |
| CI/CD | GitHub OIDC roles | Obtain short-lived deployment credentials for narrowly scoped workflow stages. |

This separation makes it easier to reason about which component is allowed to perform which class of action.

## 3. Operator API authentication

The active operator ingress is protected by a Lambda authorizer. The client supplies an `x-api-key`; the authorizer reads the expected Quick API key from AWS Secrets Manager and validates the request before the Job Receiver is invoked.

The Quick API key is intentionally kept separate from the container runtime secrets. The authorizer role can read the Quick API key, while the ECS Task Execution Role is limited to the container startup secrets required by the Agent runtime.

The public repository contains only placeholders and example configuration. Real API keys and secret values are not committed.

## 4. ECS Task Execution Role vs. ECS Task Role

This separation is one of the most important IAM choices in the project.

### ECS Task Execution Role

The execution role is used by the ECS platform while starting the task. Its permissions are limited to platform-side needs such as:

- obtaining an ECR authorization token;
- pulling the approved Agent image from ECR;
- creating log streams and sending log events to the Agent log group;
- retrieving the configured container secrets from Secrets Manager;
- decrypting those secrets through the project KMS key when the request is made via Secrets Manager.

It is not the identity used by the Python/Boto3 code inside the container.

### ECS Task Role

The task role is used by the running Agent and Skills. Its current responsibilities include:

- reading caller identity and selected CloudWatch state;
- reading project log data;
- inspecting selected project resources and cost-related signals;
- reading and updating the project DynamoDB tables;
- reading/writing the approved S3 report paths;
- reading queue attributes and consuming project queue messages where required;
- publishing project notifications to SNS;
- using the project KMS key through explicitly allowed AWS services.

The Skills themselves are still bounded by their application contracts. For example, the inspection Skills are implemented as read-only checks even though the shared runtime also needs write permissions for lifecycle state, report delivery, history handling, and notification.

## 5. Service roles

### Job Receiver Lambda

The Job Receiver role is scoped to the functions needed for unified job ingestion:

- write Lambda logs;
- create/update the Jobs lifecycle record;
- decrypt the Jobs table data key through DynamoDB/KMS;
- start the OpenClaw Step Functions state machine.

### Lambda Authorizer

The authorizer role is limited to:

- writing its own logs;
- reading the Quick API key secret;
- decrypting that secret through Secrets Manager/KMS.

### Step Functions

The state machine role can:

- send messages to the three priority queues;
- update workflow-related project records;
- publish workflow notifications where configured;
- configure the logging delivery required by Step Functions;
- use KMS through the approved SQS/SNS service paths.

### EventBridge Scheduler

The Scheduler role invokes the unified Job Receiver instead of starting ECS directly. This keeps scheduled jobs on the same validation and lifecycle path as manually submitted jobs.

### EventBridge Pipes

The Pipes role is allowed to:

- receive/delete messages from the approved SQS queues;
- decrypt queue messages through SQS/KMS;
- run the approved ECS task definition on the approved cluster;
- pass only the ECS Task Role and Task Execution Role to ECS;
- write Pipe logs.

The `ecs:RunTask` permission is constrained by the task definition and ECS cluster condition, while `iam:PassRole` is constrained to the two project task roles and to `ecs-tasks.amazonaws.com`.

## 6. KMS usage

A project KMS key is used by multiple services, but the runtime policies do not treat `kms:Decrypt` as a generic unrestricted permission. Where practical, the policy uses `kms:ViaService` conditions so decryption is accepted only through specific AWS services such as:

- Secrets Manager;
- DynamoDB;
- S3;
- SQS;
- SNS.

This reduces the chance that possession of an IAM role automatically implies arbitrary direct use of the encryption key.

## 7. Secrets handling

The project uses Secrets Manager for runtime secrets such as:

- DeepSeek API key;
- OpenClaw gateway token;
- Quick API key;
- reserved QQBot credentials.

Terraform creates secret resources, but real secret values are initialized outside the public source tree.

The Agent configuration template does not embed the DeepSeek secret value into the generated configuration. Instead, it points to the environment variable name. The runtime also avoids printing secret values in Skill output and applies redaction rules before report rendering, model input, persistence, and stdout where supported by the reporting path.

## 8. GitHub Actions authentication

Deployment automation uses GitHub OIDC instead of long-lived AWS access keys stored in GitHub.

The deployment templates request `id-token: write`, exchange the GitHub identity for short-lived AWS credentials, and assume purpose-specific roles.

The design separates at least these deployment concerns:

- image delivery;
- Terraform planning;
- Terraform apply/deployment;
- controlled dev destruction.

Production planning and production apply are intentionally separate. The production apply workflow consumes the exact reviewed plan artifact and verifies its SHA-256 before use.

The account-level GitHub OIDC provider is managed under `infra/bootstrap/github-oidc`, while environment-specific roles are created from the dev/prod Terraform roots.

## 9. Dev/prod boundary

Dev and prod use separate:

- Terraform roots and remote state paths;
- resource name prefixes;
- Secrets Manager resources;
- deployment controls and GitHub Environment scope;
- deployment IAM roles.

The GitHub OIDC module also includes a sibling-environment boundary so an environment's deployment role is not intended to manage the other environment's named resources.

This is an important design goal, but it should not be described as mathematically perfect isolation: some AWS create/list APIs do not support resource-level restrictions and therefore still rely on trust-policy scope, naming/tagging rules, reviewed plans, and workflow controls.

## 10. Explicit Deny: operational lesson

A controlled Dev fault-injection exercise demonstrated an important IAM behavior twice:

- an explicit deny on `cloudwatch:ListMetrics` caused the healthcheck workload to fail even though the normal task policy allowed the action;
- an explicit deny on `dynamodb:UpdateItem` allowed the inspection workload itself to finish but prevented the Jobs lifecycle record from reaching its terminal state.

The lesson is that **explicit Deny overrides Allow**. The correct recovery path was to remove the injected deny and restore the known-good policy state—not to add broader Allow statements.

## 11. Public-repository controls

The public repository adds a separate safety layer:

- deployment workflows are stored under `.github/deployment-templates/` instead of being active workflows;
- only CI is active;
- CI rejects Terraform state/plan files, private variable files, `.env` files, private keys, packaged private deployment artifacts, and common credential signatures;
- real AWS account IDs, role ARNs, state bucket names, secrets, and environment outputs are replaced or excluded.

This repository policy is a publication safeguard, not a substitute for runtime IAM.

## 12. Security boundaries that are intentionally not claimed

The current project does not claim:

- a zero-trust multi-tenant architecture;
- private-subnet-only production networking;
- automatic credential rotation orchestration beyond the underlying AWS service capabilities;
- unrestricted autonomous remediation;
- complete prevention of every possible privilege-escalation path in an arbitrary AWS account;
- that the disabled deployment templates are safe to enable unchanged outside the original project environment.

The intended portfolio value is the ability to inspect the actual IAM boundaries, explain why they exist, and reason about failure modes without presenting the prototype as a fully hardened enterprise platform.
