# Deployment & Setup

[中文](deployment.zh-CN.md)

## 1. Scope

This document describes the deployment model represented by the current public source. It separates:

- local/static validation;
- account bootstrap;
- dev deployment;
- prod deployment;
- optional GitHub Actions deployment templates.

The repository contains the Terraform and scripts required to reproduce the design, but a complete deployment into a brand-new AWS account has **not** been revalidated as a one-command public installation. Treat the procedure as an engineering deployment guide that still requires review of account-specific settings, IAM trust, secrets, cost, and Terraform plans.

## 2. Prerequisites

Recommended local tools:

- Terraform compatible with the repository constraints; public CI currently pins Terraform `1.15.8`;
- AWS CLI;
- Docker;
- Git;
- Bash;
- `jq` and common Unix utilities for operational scripts;
- Python 3 for local tests.

AWS deployment should use the intended account and `ap-northeast-1` (Tokyo). The Terraform environment roots enforce Tokyo as the current region baseline.

Before any apply, configure the real account-specific values outside the public repository. Public values such as `000000000000`, `123456789012`, `YOUR_GITHUB_OWNER/...`, zeroed image digests, and example emails are placeholders.

## 3. Files that must remain private

Do not commit or publish:

- `terraform.tfvars`;
- `terraform.tfstate` or backups;
- saved `*.tfplan` files;
- `.env` files;
- PEM/private-key material;
- real AWS account IDs and environment-specific resource identifiers;
- secret values;
- deployment evidence that contains private endpoints or identifiers.

The active public CI includes checks that reject several of these file classes and common credential signatures.

## 4. Terraform layout

```text
infra/
├── bootstrap/
│   ├── remote-state/
│   └── github-oidc/
├── envs/
│   ├── dev/
│   └── prod/
├── modules/
└── scripts/
```

### Bootstrap roots

`infra/bootstrap/remote-state` creates the Terraform state storage foundation.

`infra/bootstrap/github-oidc` manages the account-level GitHub Actions OIDC provider. Keeping the provider in a separate bootstrap state avoids duplicated ownership across dev and prod environment states.

### Environment roots

`infra/envs/dev` and `infra/envs/prod` compose the same reusable modules into separate environments with independent state paths and resource prefixes.

## 5. Validate before deployment

Run static Terraform validation first:

```bash
./infra/scripts/validate.sh
```

The script:

- runs recursive `terraform fmt -check`;
- verifies each Terraform root has configuration files and a provider lock file;
- initializes each root with `-backend=false` and a temporary plugin cache;
- validates `bootstrap/remote-state`;
- validates `bootstrap/github-oidc`;
- validates `envs/dev`;
- validates `envs/prod`.

A successful run ends with:

```text
TERRAFORM_VALIDATION_PASSED
```

## 6. New-account bootstrap sequence

A reasonable fresh-account sequence is:

1. Review and apply `infra/bootstrap/remote-state` to create the state bucket. Its bootstrap state is initially local and must be protected privately.
2. Configure `infra/bootstrap/github-oidc` against the remote backend and create or import the account-level GitHub OIDC provider. An existing provider must not be blindly created a second time.
3. Prepare private dev configuration. Keep schedulers disabled while bootstrapping.
4. Apply the dev foundation and create the ECR repository, secrets containers, IAM roles, logs, data stores, orchestration resources, and task definition.
5. Build and push the OpenClaw Agent image to ECR, then use its immutable SHA-256 digest in Terraform.
6. Initialize the secret values required by the runtime.
7. Apply the reviewed dev plan with the real image digest and run smoke validation.
8. After dev is validated, prepare and apply prod using the already validated image artifact and independent prod secrets/configuration.

This sequence is intentionally conservative: infrastructure foundation first, immutable image second, runtime activation after the required secrets and image are available.

## 7. Required runtime secrets

The current environment creates secret resources for at least the following values:

| Secret purpose | Runtime key |
| --- | --- |
| DeepSeek API key | `DEEPSEEK_API_KEY` |
| OpenClaw gateway token | `OPENCLAW_GATEWAY_TOKEN` |
| Quick API key | `QUICK_API_KEY` |
| QQBot application ID | `QQBOT_APP_ID` |
| QQBot client secret | `QQBOT_CLIENT_SECRET` |

The presence of QQBot configuration does not mean the public project depends on that channel; it is optional and disabled by default in the current Terraform variables.

Secret **resources** may be created by Terraform, but secret **values** should be initialized out of band and must never be committed.

## 8. Existing-environment plan/apply workflow

For an already initialized environment:

```bash
./infra/scripts/validate.sh
./infra/scripts/plan.sh dev
```

`plan.sh` verifies the AWS context, initializes the selected environment, hydrates current environment values, writes a saved plan, writes a human-readable plan, and records a SHA-256 hash. It prints the resulting `PLAN_FILE` and evidence directory.

After reviewing the plan:

```bash
./infra/scripts/deploy.sh dev /absolute/path/to/reviewed/dev.tfplan
```

For prod, `deploy.sh` requires the operator to type:

```text
DEPLOY-PROD
```

before the saved plan is applied.

The workflow intentionally applies a previously reviewed plan rather than re-running a new implicit plan during deployment.

## 9. Image handling

The runtime image is expected to be addressed by an immutable digest:

```text
<account>.dkr.ecr.ap-northeast-1.amazonaws.com/<repo>@sha256:<digest>
```

The public Terraform files contain a zeroed SHA-256 placeholder. Deployment should replace it with the digest of a built and verified image.

The dev deployment template tags images by source commit and then resolves the immutable digest. Prod automation promotes the exact validated digest from dev to prod ECR and verifies that the digest is unchanged during promotion.

## 10. Scheduler and Pipes defaults

Current dev variables default to:

```text
eventbridge_pipes_enabled = true
eventbridge_scheduler_enabled = false
```

This means the queue-to-Fargate execution path is enabled while recurring schedules remain off unless explicitly enabled.

Keeping the scheduler off by default is intentional: the project should not begin launching periodic tasks merely because infrastructure was deployed.

## 11. GitHub Actions deployment templates

Only CI is active in `.github/workflows/` in the public repository. Cloud deployment workflows are stored under:

```text
.github/deployment-templates/
```

They are provided as inspectable templates and do not execute automatically from that directory.

The templates cover:

- dev build / image delivery / Terraform apply / smoke test;
- prod image promotion and reviewable Terraform Plan;
- prod Apply of the exact reviewed plan artifact;
- dev destroy flow.

Before enabling them, replace all public placeholders, configure GitHub Environments, review OIDC trust and IAM permissions, and validate the Terraform backend.

## 12. Production Plan / Apply controls

The prod templates intentionally separate Plan and Apply.

**Plan Prod**:

- accepts an image digest already validated in dev;
- promotes that exact artifact to the prod ECR repository;
- creates a saved Terraform plan;
- writes a human-readable plan;
- hashes the plan;
- stores metadata and uploads the plan artifact for review.

**Apply Prod**:

- requires a previously generated Plan run ID;
- requires explicit `APPLY-PROD` confirmation;
- downloads the reviewed artifact;
- validates metadata and SHA-256;
- checks out the source commit associated with the Plan;
- applies the exact saved plan;
- runs a prod smoke test;
- runs an immediate no-drift check.

## 13. Post-deployment verification

Deployment should not be considered complete because `terraform apply` returned successfully. Verify at least:

- API Gateway / authorizer / Job Receiver path;
- Job record creation and state transitions;
- Step Functions routing;
- SQS message consumption;
- EventBridge Pipe state;
- ECS task launch and exit status;
- CloudWatch logs;
- report/history persistence where applicable;
- SNS notification behavior;
- expected scheduler state;
- no unexpected Terraform drift after prod deployment.

The repository includes smoke, alert, final-regression, DLQ-redrive, scheduler-history, and cost-residue scripts for controlled validation. Some of these change test state; review them before running against any environment.

## 14. Cost and safety notes

- AWS Budgets is an alerting mechanism, not a hard spending cap.
- Fargate, EFS, logs, data stores, and repeated test execution can create cost.
- The current baseline intentionally avoids a NAT Gateway.
- Do not enable schedules merely to prove they exist; enable them only when recurring workload and cost are intended.
- Do not broaden IAM policies as a generic response to deployment failures. Diagnose the specific denied action and preserve least-privilege boundaries.
