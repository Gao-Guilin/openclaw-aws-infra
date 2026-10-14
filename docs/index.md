# Documentation Index & Quick Start

[中文](index.zh-CN.md)

## 1. Documentation map

OpenClaw-AWS uses separate English and Simplified Chinese documents.

| # | English | 中文 |
| --- | --- | --- |
| 1 | [Project Overview](../README.md) | [项目概览](../README.zh-CN.md) |
| 2 | [Architecture](architecture.md) | [系统架构](architecture.zh-CN.md) |
| 3 | [Deployment & Setup](deployment.md) | [部署与环境配置](deployment.zh-CN.md) |
| 4 | [CI/CD & GitHub OIDC](ci-cd.md) | [CI/CD 与 GitHub OIDC](ci-cd.zh-CN.md) |
| 5 | [Security & IAM Design](security-iam.md) | [安全与 IAM 权限设计](security-iam.zh-CN.md) |
| 6 | [Operations & Job Lifecycle](operations-lifecycle.md) | [运维流程与任务生命周期](operations-lifecycle.zh-CN.md) |
| 7 | [Skills & Report Pipeline](skills-reporting.md) | [Skills 与自动报告链路](skills-reporting.zh-CN.md) |
| 8 | [Incident & Troubleshooting Records](incidents.md) | [故障处理与排障记录](incidents.zh-CN.md) |
| 9 | [Changes & Architecture Decisions](changes-decisions.md) | [重要变更与架构决策](changes-decisions.zh-CN.md) |
| 10 | [Validation & Evidence](validation-evidence.md) | [验证结果与项目证据](validation-evidence.zh-CN.md) |
| 11 | [Limitations & Known Constraints](limitations.md) | [已知限制与设计约束](limitations.zh-CN.md) |
| 12 | Documentation Index & Quick Start | [文档导航与快速开始](index.zh-CN.md) |

## 2. Suggested reading paths

### Recruiter / hiring-manager review

If you have about 10 minutes:

1. [Project Overview](../README.md)
2. [Architecture](architecture.md)
3. [Incident & Troubleshooting Records](incidents.md)
4. [Validation & Evidence](validation-evidence.md)

This path shows the project scope, AWS architecture, troubleshooting ability, and validation quality without requiring a full code review.

### Cloud / DevOps engineer review

For a deeper technical review:

1. [Architecture](architecture.md)
2. [Security & IAM Design](security-iam.md)
3. [CI/CD & GitHub OIDC](ci-cd.md)
4. [Operations & Job Lifecycle](operations-lifecycle.md)
5. [Skills & Report Pipeline](skills-reporting.md)
6. [Changes & Architecture Decisions](changes-decisions.md)
7. [Limitations & Known Constraints](limitations.md)

### Troubleshooting-focused review

For incident-response discussion:

1. [Operations & Job Lifecycle](operations-lifecycle.md)
2. [Incident & Troubleshooting Records](incidents.md)
3. [Validation & Evidence](validation-evidence.md)

## 3. Repository layout

```text
.
├── .github/
│   ├── workflows/
│   │   └── ci.yml
│   └── deployment-templates/
├── infra/
│   ├── bootstrap/
│   ├── envs/
│   │   ├── dev/
│   │   └── prod/
│   ├── modules/
│   └── scripts/
├── openclaw-agent/
│   ├── config/
│   ├── prompts/
│   ├── skills/
│   ├── tests/
│   ├── Dockerfile
│   └── entrypoint.sh
├── docs/
└── test.sh
```

The initial sanitized public snapshot intentionally excludes real Terraform state, private variable files, private deployment outputs, and raw cloud evidence.

## 4. Quick start: validate the source locally

The fastest safe way to review the project is to run the same categories of checks used by public CI.

### Prerequisites

Recommended tools:

- Git
- Bash
- Python 3
- Terraform
- Docker

AWS CLI is only required for account-aware deployment and real-cloud operational scripts.

The public CI currently validates with Terraform `1.15.8`.

## 5. Clone

```bash
git clone https://github.com/Gao-Guilin/openclaw-aws-infra.git
cd openclaw-aws-infra
```

## 6. Validate Terraform

```bash
./infra/scripts/validate.sh
```

The script:

- checks Terraform formatting;
- initializes provider plugins with remote backends disabled;
- validates remote-state bootstrap;
- validates GitHub OIDC bootstrap;
- validates Dev;
- validates Prod.

Expected final marker:

```text
TERRAFORM_VALIDATION_PASSED
```

This command does not apply infrastructure.

## 7. Run Python tests

```bash
python3 -m venv .venv
.venv/bin/pip install pytest -r openclaw-agent/requirements.txt

.venv/bin/python -m pytest -q \
  openclaw-agent/tests \
  infra/modules/lambda/tests
```

At the public release baseline, the CI result was:

```text
58 passed
```

The tests use local/mocked behavior and do not require publishing the original AWS account credentials.

## 8. Check Shell scripts

On a Linux environment with ShellCheck:

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 -n1 bash -n

find . -type f -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 shellcheck -x -S error
```

## 9. Build the Agent image

```bash
docker build -t openclaw-aws-agent:local ./openclaw-agent
```

This validates the container build path only. It does not connect the image to a real AWS environment.

## 10. Inspect the key runtime path

For code review, the most useful starting files are:

```text
infra/envs/dev/main.tf
infra/envs/prod/main.tf
infra/modules/iam/main.tf
infra/modules/ecs/main.tf
infra/modules/lambda/main.tf
infra/modules/stepfunctions/main.tf
infra/modules/eventbridge/main.tf
openclaw-agent/entrypoint.sh
openclaw-agent/skills/
.github/workflows/ci.yml
```

These files expose the main architecture, IAM boundaries, lifecycle, task routing, and validation model.

## 11. Do not deploy from placeholders without configuration

The public repository is sanitized.

Examples such as:

```text
000000000000
YOUR_GITHUB_OWNER/...
```

are placeholders.

Before using any deployment template, a reviewer would need to configure:

- a real AWS account and region context;
- Terraform backend;
- private `terraform.tfvars`;
- GitHub OIDC;
- environment-specific IAM roles;
- Secrets Manager values;
- GitHub Environment controls.

See [Deployment & Setup](deployment.md).

## 12. Deployment workflows are intentionally inactive

Only public CI is active under:

```text
.github/workflows/
```

AWS deployment workflows are retained as reference templates under:

```text
.github/deployment-templates/
```

Moving them into the active workflow directory without adapting account-specific configuration is not recommended.

## 13. Quick conceptual runtime trace

A normal operator-triggered Job follows:

```text
API Gateway
→ Lambda Authorizer
→ Job Receiver
→ DynamoDB Jobs
→ Step Functions
→ SQS
→ EventBridge Pipe
→ ECS Fargate
→ selected Skill
→ source result
→ optional report/history/notification
→ terminal Jobs state
```

Useful interpretation rules:

```text
202 Accepted
≠ task success

Step Functions success
≠ Skill success

source overall_ok
≠ guaranteed terminal-state persistence
```

These distinctions are central to the project's troubleshooting model.

## 14. Safety rules for local review

Do not add the following to Git:

```text
terraform.tfstate
terraform.tfstate.*
*.tfplan
terraform.tfvars
.env
*.pem
*.key
*.secret
real account IDs
real secret values
```

Use example files and private local configuration instead.

## 15. Where to go next

If the goal is to understand **why the system looks this way**, read:

- [Changes & Architecture Decisions](changes-decisions.md)

If the goal is to understand **how failure is diagnosed**, read:

- [Incident & Troubleshooting Records](incidents.md)

If the goal is to understand **what the repository actually proves**, read:

- [Validation & Evidence](validation-evidence.md)
- [Limitations & Known Constraints](limitations.md)
