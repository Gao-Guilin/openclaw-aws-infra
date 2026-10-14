# 文档导航与快速开始

[English](index.md)

## 1. 文档总览

OpenClaw-AWS 的公开文档采用英文版与简体中文版分离的形式。

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
| 12 | [Documentation Index & Quick Start](index.md) | 文档导航与快速开始 |

## 2. 推荐阅读顺序

### HR / Hiring Manager 快速查看

如果只有大约 10 分钟：

1. [项目概览](../README.zh-CN.md)
2. [系统架构](architecture.zh-CN.md)
3. [故障处理与排障记录](incidents.zh-CN.md)
4. [验证结果与项目证据](validation-evidence.zh-CN.md)

这一条路径可以快速看到项目范围、AWS 架构、排障能力和验证质量，不要求深入阅读所有源码。

### Cloud / DevOps Engineer 技术审阅

建议：

1. [系统架构](architecture.zh-CN.md)
2. [安全与 IAM 权限设计](security-iam.zh-CN.md)
3. [CI/CD 与 GitHub OIDC](ci-cd.zh-CN.md)
4. [运维流程与任务生命周期](operations-lifecycle.zh-CN.md)
5. [Skills 与自动报告链路](skills-reporting.zh-CN.md)
6. [重要变更与架构决策](changes-decisions.zh-CN.md)
7. [已知限制与设计约束](limitations.zh-CN.md)

### 重点查看排障能力

建议：

1. [运维流程与任务生命周期](operations-lifecycle.zh-CN.md)
2. [故障处理与排障记录](incidents.zh-CN.md)
3. [验证结果与项目证据](validation-evidence.zh-CN.md)

## 3. 仓库目录

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

初始脱敏 Public Snapshot 明确排除了真实 Terraform State、私有变量、真实部署 Output 和原始云端证据。

## 4. Quick Start：先在本地验证源码

最安全、最快的项目查看方式，是先重复 Public CI 中的检查类型。

### 推荐工具

- Git
- Bash
- Python 3
- Terraform
- Docker

只有涉及真实 AWS Account 的部署和云端运维 Script 才需要 AWS CLI。

Public CI 当前使用 Terraform `1.15.8` 验证。

## 5. Clone

```bash
git clone https://github.com/Gao-Guilin/openclaw-aws-infra.git
cd openclaw-aws-infra
```

## 6. Terraform Validation

```bash
./infra/scripts/validate.sh
```

脚本会：

- 检查 Terraform Format；
- 在不连接 Remote Backend 的情况下初始化 Provider；
- 验证 Remote State Bootstrap；
- 验证 GitHub OIDC Bootstrap；
- 验证 Dev；
- 验证 Prod。

成功时最终输出：

```text
TERRAFORM_VALIDATION_PASSED
```

该命令不会 Apply AWS Infrastructure。

## 7. Python Tests

```bash
python3 -m venv .venv
.venv/bin/pip install pytest -r openclaw-agent/requirements.txt

.venv/bin/python -m pytest -q \
  openclaw-agent/tests \
  infra/modules/lambda/tests
```

Public Release 基线 CI：

```text
58 passed
```

这些测试主要使用本地 / Mock 行为，不需要公开原 AWS Account 的 Credentials。

## 8. Shell 检查

Linux + ShellCheck 环境可运行：

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 -n1 bash -n

find . -type f -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 shellcheck -x -S error
```

## 9. 构建 Agent Image

```bash
docker build -t openclaw-aws-agent:local ./openclaw-agent
```

这只验证 Container Build Path，不会把镜像连接到真实 AWS 环境。

## 10. 最值得先看的源码

做 Code Review 时，建议优先查看：

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

这些文件能够直接看到：

- 总体架构；
- IAM Boundary；
- Job Lifecycle；
- Task Routing；
- CI Validation Model。

## 11. 不要直接拿 Placeholder 部署

Public Repo 已做脱敏。

例如：

```text
000000000000
YOUR_GITHUB_OWNER/...
```

都只是 Placeholder。

真正启用 Deployment 之前需要配置：

- 真实 AWS Account / Region；
- Terraform Backend；
- 私有 `terraform.tfvars`；
- GitHub OIDC；
- 环境级 IAM Role；
- Secrets Manager Value；
- GitHub Environment 控制。

详细见 [部署与环境配置](deployment.zh-CN.md)。

## 12. 部署 Workflow 默认不激活

Public Repo 只有 CI 位于：

```text
.github/workflows/
```

AWS Deployment Workflow 被作为参考模板保存在：

```text
.github/deployment-templates/
```

不建议在没有完成环境级配置和审阅的情况下直接把它们移动到 Active Workflow 目录。

## 13. 一条正常 Job 的概念链路

Operator 主动任务：

```text
API Gateway
→ Lambda Authorizer
→ Job Receiver
→ DynamoDB Jobs
→ Step Functions
→ SQS
→ EventBridge Pipe
→ ECS Fargate
→ 对应 Skill
→ 源 Result
→ 可选 Report / History / Notification
→ Jobs 终态
```

排障时必须记住：

```text
202 Accepted
≠ Task Success

Step Functions Success
≠ Skill Success

source overall_ok
≠ 一定成功写入最终 Jobs State
```

这是整个项目排障模型中非常重要的三条边界。

## 14. 本地审阅的安全规则

下面内容不要加入 Git：

```text
terraform.tfstate
terraform.tfstate.*
*.tfplan
terraform.tfvars
.env
*.pem
*.key
*.secret
真实 Account ID
真实 Secret Value
```

应使用 Example File 与私有 Local Configuration。

## 15. 下一步看什么

如果你想理解**为什么项目设计成现在这样**：

- [重要变更与架构决策](changes-decisions.zh-CN.md)

如果你想重点看**故障是怎么定位的**：

- [故障处理与排障记录](incidents.zh-CN.md)

如果你想知道**这个仓库目前究竟能够证明什么**：

- [验证结果与项目证据](validation-evidence.zh-CN.md)
- [已知限制与设计约束](limitations.zh-CN.md)
