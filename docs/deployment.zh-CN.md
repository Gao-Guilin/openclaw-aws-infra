# 部署与环境配置

[English](deployment.md)

## 1. 文档范围

本文描述当前公开源码所代表的部署模型，并将部署过程拆分为：

- 本地 / 静态校验；
- AWS 账号 Bootstrap；
- Dev 部署；
- Prod 部署；
- 可选的 GitHub Actions 部署模板。

仓库已经包含复现架构所需的 Terraform 和脚本，但当前公开版本 **没有在另一个全新 AWS 账号中重新验证“一条命令从零部署”**。因此应把本文理解为需要人工审阅的工程部署指南，而不是无需检查即可执行的一键安装器。

## 2. 前置工具

建议本地准备：

- 与仓库约束兼容的 Terraform；公开 CI 当前固定使用 `1.15.8`；
- AWS CLI；
- Docker；
- Git；
- Bash；
- `jq` 及常用 Unix 工具；
- Python 3，用于本地测试。

AWS 部署应使用正确账号，并部署到 `ap-northeast-1`（东京）。当前 Terraform Dev / Prod Root 都对东京区域进行了约束。

任何 Apply 前都必须在公开仓库之外准备真实账号配置。源码中的 `000000000000`、`123456789012`、`YOUR_GITHUB_OWNER/...`、全零镜像 Digest 和示例邮箱均为占位值。

## 3. 必须保持私有的文件和数据

不要提交或公开：

- `terraform.tfvars`；
- `terraform.tfstate` 及其 Backup；
- 保存后的 `*.tfplan`；
- `.env`；
- PEM / Private Key；
- 真实 AWS Account ID 和环境唯一资源标识；
- Secret Value；
- 包含私有 Endpoint 或标识符的部署证据。

当前公开 CI 会主动拒绝其中多类文件以及常见凭据特征。

## 4. Terraform 目录结构

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

### Bootstrap Root

`infra/bootstrap/remote-state` 用于创建 Terraform Remote State 所需的基础资源。

`infra/bootstrap/github-oidc` 单独管理账号级 GitHub Actions OIDC Provider。这样可以避免 Dev 和 Prod State 同时拥有同一个账号级身份提供者。

### Environment Root

`infra/envs/dev` 和 `infra/envs/prod` 组合相同的可复用 Module，但使用独立 State Path 和资源名前缀。

## 5. 部署前校验

首先执行：

```bash
./infra/scripts/validate.sh
```

该脚本会：

- 执行递归 `terraform fmt -check`；
- 检查每个 Terraform Root 是否存在配置和 Provider Lock File；
- 使用临时 Plugin Cache，并以 `-backend=false` 初始化；
- 校验 `bootstrap/remote-state`；
- 校验 `bootstrap/github-oidc`；
- 校验 `envs/dev`；
- 校验 `envs/prod`。

全部通过后会输出：

```text
TERRAFORM_VALIDATION_PASSED
```

## 6. 全新账号建议初始化顺序

较稳妥的从零流程为：

1. 审阅并 Apply `infra/bootstrap/remote-state`，创建 Remote State Bucket；其初始 Bootstrap State 需要私下保存。
2. 为 `infra/bootstrap/github-oidc` 配置 Remote Backend，创建或导入账号级 GitHub OIDC Provider；如果账号中已经存在 Provider，不应再次创建。
3. 准备私有 Dev 配置；Bootstrap 阶段保持 Scheduler 关闭。
4. Apply Dev 基础设施，创建 ECR、Secret 资源、IAM Role、日志、数据存储、编排资源和 Task Definition。
5. 构建 OpenClaw Agent 镜像并 Push 到 ECR，取得不可变 SHA-256 Digest。
6. 在仓库外初始化运行所需 Secret Value。
7. 使用真实镜像 Digest 重新审阅 Dev Plan、Apply，并执行 Smoke Test。
8. Dev 验证通过后，再使用同一份已验证 Artifact 和独立 Prod Secret / 配置初始化 Prod。

这个顺序刻意将“基础设施”“不可变镜像”“运行激活”分开，减少一次性引入过多变量。

## 7. 运行时 Secret

当前环境至少创建以下 Secret 资源：

| Secret 用途 | Runtime Key |
| --- | --- |
| DeepSeek API Key | `DEEPSEEK_API_KEY` |
| OpenClaw Gateway Token | `OPENCLAW_GATEWAY_TOKEN` |
| Quick API Key | `QUICK_API_KEY` |
| QQBot App ID | `QQBOT_APP_ID` |
| QQBot Client Secret | `QQBOT_CLIENT_SECRET` |

QQBot 配置存在不代表公开项目依赖该通道；当前 Terraform 中它是可选能力并且默认关闭。

Terraform 可以创建 Secret **资源**，但 Secret **值**应通过仓库外流程初始化，绝不能提交到 Git。

## 8. 已有环境的 Plan / Apply

对已经初始化的环境：

```bash
./infra/scripts/validate.sh
./infra/scripts/plan.sh dev
```

`plan.sh` 会验证 AWS Context、初始化目标环境、恢复当前环境变量，保存 Binary Plan、生成可读 Plan，并保存 SHA-256 Hash。脚本最终输出 `PLAN_FILE` 和 Evidence Directory。

人工审阅后：

```bash
./infra/scripts/deploy.sh dev /absolute/path/to/reviewed/dev.tfplan
```

如果是 Prod，`deploy.sh` 会额外要求用户输入：

```text
DEPLOY-PROD
```

然后才允许 Apply。

这里的重要原则是：**Apply 已经人工审阅过的 Saved Plan，而不是部署时隐式重新 Plan。**

## 9. 镜像管理

运行镜像应使用不可变 Digest：

```text
<account>.dkr.ecr.ap-northeast-1.amazonaws.com/<repo>@sha256:<digest>
```

公开 Terraform 中的 SHA-256 是全零占位值。真实部署必须替换为已经构建和验证过的镜像 Digest。

Dev 部署模板使用 Source Commit 生成 Tag，并最终解析不可变 Digest；Prod 自动化则把 Dev 中已验证的同一个 Digest Promote 到 Prod ECR，并检查 Promote 后 Digest 没有变化。

## 10. Scheduler 与 Pipes 默认值

当前 Dev 变量默认：

```text
eventbridge_pipes_enabled = true
eventbridge_scheduler_enabled = false
```

也就是说，SQS → Fargate 执行链路默认启用，而周期调度不会自动启动。

Scheduler 默认关闭是刻意设计：项目不应因为完成一次基础设施部署就自动持续产生任务和费用。

## 11. GitHub Actions 部署模板

公开仓库中只有 CI 位于 `.github/workflows/` 并处于启用状态。云部署 Workflow 被放在：

```text
.github/deployment-templates/
```

GitHub 不会从这个目录自动运行它们，因此它们只是可检查的模板。

当前模板包括：

- Dev 构建 / 镜像交付 / Terraform Apply / Smoke Test；
- Prod 镜像 Promote 与可审阅 Terraform Plan；
- Prod 对“同一份已审阅 Plan”的 Apply；
- Dev Destroy 流程。

真正启用前必须替换所有公开占位值，配置 GitHub Environments，重新审阅 OIDC Trust / IAM 权限，并确认 Terraform Backend。

## 12. Prod Plan / Apply 控制

Prod 自动化刻意把 Plan 和 Apply 分开。

**Plan Prod**：

- 输入已经在 Dev 验证的 Image Digest；
- Promote 完全相同的 Artifact 到 Prod ECR；
- 生成 Saved Terraform Plan；
- 保存可读 Plan；
- 保存 Plan SHA-256；
- 记录 Metadata；
- 上传 Plan Artifact 供人工审阅。

**Apply Prod**：

- 要求提供此前 Plan Run ID；
- 要求显式输入 `APPLY-PROD`；
- 下载已经审阅的 Plan Artifact；
- 校验 Metadata 和 SHA-256；
- Checkout 生成该 Plan 时对应的 Source Commit；
- Apply 同一份 Saved Plan；
- 执行 Prod Smoke Test；
- 执行一次即时 No-Drift 检查。

## 13. 部署后验证

不能因为 `terraform apply` 成功就直接把部署判定为完成。至少应验证：

- API Gateway / Authorizer / Job Receiver；
- Job 创建和生命周期状态；
- Step Functions 路由；
- SQS 消费；
- EventBridge Pipe 状态；
- ECS Task 启动及 Exit Status；
- CloudWatch Logs；
- 适用场景下的 Report / History 持久化；
- SNS 通知；
- Scheduler 是否保持预期状态；
- Prod Apply 后是否存在非预期 Terraform Drift。

仓库中提供 Smoke、Alert、Final Regression、DLQ Redrive、Scheduler History、Cost Residue 等脚本。部分脚本会改变测试状态或重新投递任务，执行前必须先读脚本并确认目标环境。

## 14. 成本与安全提醒

- AWS Budgets 是告警机制，不是强制消费上限。
- Fargate、EFS、日志、数据存储和重复测试都会产生费用。
- 当前基线刻意不创建 NAT Gateway。
- 不要为了证明 Scheduler 存在就随意打开周期任务；只有确实需要持续任务时才启用。
- 部署遇到 AccessDenied 时，不应直接把 IAM 权限整体放大。应先定位具体 Action 和资源边界，再做最小化调整。
