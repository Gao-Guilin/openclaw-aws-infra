# 安全与 IAM 权限设计

[English](security-iam.md)

## 1. 安全目标

OpenClaw-AWS 面向单用户、低并发的 CloudOps / AIOps 原型场景。安全设计重点不是构建一个可以任意操作云环境的“万能 Agent”，而是建立 **清晰的信任边界、短期凭据、角色分离、Secret 隔离和可审计执行链路**。

核心原则是：系统可以通过预定义流程检查、分析和生成报告；真正会修改基础设施的权限只存在于明确受控的部署路径中。

## 2. 主要信任边界

项目没有让所有组件共用一个大权限 AWS 身份，而是按职责拆分。

| 边界 | 身份 / 控制方式 | 主要职责 |
| --- | --- | --- |
| 用户主动接口 | API Gateway + Lambda Authorizer | 对用户主动请求进行鉴权。 |
| Job 接收 | Job Receiver Lambda Role | 校验请求、写生命周期记录、启动 Step Functions。 |
| 工作流路由 | Step Functions Role | 按优先级把任务投递到对应队列。 |
| 队列到运行时 | EventBridge Pipes Role | 消费 SQS，并启动指定 ECS Task Definition。 |
| 定时入口 | EventBridge Scheduler Role | 调用统一 Job Receiver。 |
| 容器启动 | ECS Task Execution Role | 拉取镜像、获取运行时 Secret、写启动/运行日志。 |
| 容器业务代码 | ECS Task Role | 为 Skill 提供需要的 AWS 读取和有限的项目状态写入权限。 |
| CI/CD | GitHub OIDC Roles | 通过短期 AWS 凭据执行受控的部署阶段。 |

这样可以比较明确地回答“哪个组件为什么需要什么权限”。

## 3. 用户主动接口鉴权

当前主动入口由 Lambda Authorizer 保护。客户端提交 `x-api-key`，Authorizer 从 AWS Secrets Manager 读取 Quick API Key 并完成校验，通过后才允许 Job Receiver 处理请求。

Quick API Key 与容器运行时 Secret 分开管理。Authorizer Role 可以读取 Quick API Key；ECS Task Execution Role 只获取 Agent 容器启动所需的那组 Secret。

公开仓库只保留占位配置和示例值，不包含真实 API Key 或 Secret Value。

## 4. ECS Task Execution Role 与 ECS Task Role

这是项目中最重要的 IAM 分层之一。

### ECS Task Execution Role

Execution Role 由 ECS 平台在启动 Task 时使用，权限主要服务于“把容器启动起来”，包括：

- 获取 ECR Authorization Token；
- 从指定 ECR Repository 拉取 Agent 镜像；
- 创建 Log Stream 并向 Agent Log Group 写日志；
- 从 Secrets Manager 读取容器所需 Secret；
- 通过 Secrets Manager / KMS 解密相应 Secret。

它不是容器内部 Python/Boto3 代码实际使用的身份。

### ECS Task Role

Task Role 由 Agent 和 Skills 在运行过程中使用，目前包括：

- 获取 Caller Identity、读取部分 CloudWatch 状态；
- 读取项目日志；
- 检查部分项目资源和成本相关信号；
- 读取并更新项目 DynamoDB 表；
- 读取/写入限定的 S3 报告路径；
- 在需要时读取队列属性及消费项目队列；
- 向项目 SNS Topic 发布通知；
- 通过指定 AWS 服务使用项目 KMS Key。

需要注意：各个巡检 Skill 在应用层仍然坚持只读检查。Task Role 中存在写权限，是因为共享运行时还需要写 Job 生命周期、报告、历史和通知，并不表示巡检 Skill 可以随意修改基础设施。

## 5. 各服务角色

### Job Receiver Lambda

Job Receiver Role 只覆盖统一任务接收链路所需能力：

- 写 Lambda 日志；
- 创建/更新 Jobs 生命周期记录；
- 通过 DynamoDB/KMS 访问 Jobs 表；
- 启动 OpenClaw Step Functions State Machine。

### Lambda Authorizer

Authorizer Role 主要允许：

- 写自己的日志；
- 读取 Quick API Key Secret；
- 通过 Secrets Manager/KMS 解密该 Secret。

### Step Functions

State Machine Role 可以：

- 向三条优先级 SQS 发送消息；
- 更新工作流相关项目记录；
- 在需要时发送工作流通知；
- 配置 Step Functions 所需日志投递；
- 通过受约束的 SQS/SNS 服务路径使用 KMS。

### EventBridge Scheduler

Scheduler 不直接启动 ECS，而是调用统一 Job Receiver。这样定时任务仍然经过相同的请求校验、Job 建档和状态链路。

### EventBridge Pipes

Pipes Role 可以：

- 从指定 SQS 队列 Receive/Delete Message；
- 通过 SQS/KMS 解密消息；
- 在指定 ECS Cluster 上运行指定 Task Definition；
- 只把项目的 ECS Task Role 和 Task Execution Role Pass 给 ECS；
- 写 Pipe 日志。

`ecs:RunTask` 受 Task Definition 和 Cluster 条件限制；`iam:PassRole` 只覆盖项目的两个 Task Role，并要求 `iam:PassedToService = ecs-tasks.amazonaws.com`。

## 6. KMS 使用边界

项目的 KMS Key 会被多个服务使用，但运行时策略并没有把 `kms:Decrypt` 当成不受限制的通用权限。

在适合的地方，策略通过 `kms:ViaService` 限定调用路径，例如只允许通过：

- Secrets Manager；
- DynamoDB；
- S3；
- SQS；
- SNS。

这样可以降低“拿到某个 Role 就可以任意直接使用 KMS Key”的风险。

## 7. Secret 管理

项目使用 Secrets Manager 保存运行时敏感信息，例如：

- DeepSeek API Key；
- OpenClaw Gateway Token；
- Quick API Key；
- 预留的 QQBot 凭据。

Terraform 负责创建 Secret 资源，但真实 Secret Value 在 Git 之外初始化。

Agent 配置模板也不会把 DeepSeek Secret 明文写入最终配置，而是引用对应环境变量名称。报告链路还会在模型输入、渲染、持久化和 stdout 输出前对受支持的敏感字段和常见 Secret Pattern 做脱敏。

## 8. GitHub Actions 身份认证

部署自动化使用 GitHub OIDC，而不是把长期 AWS Access Key 存进 GitHub。

部署 Workflow 请求：

```text
id-token: write
```

随后用 GitHub 身份换取短期 AWS 凭据，再 Assume 对应职责的 IAM Role。

当前设计将部署权限拆分为多个阶段，例如：

- 镜像交付；
- Terraform Plan；
- Terraform Apply / Deploy；
- 受控 Dev Destroy。

Prod Plan 与 Prod Apply 明确分离。Apply 会读取已经审阅的 Plan Artifact，并校验 SHA-256，避免“审阅的是一份 Plan，实际 Apply 的却是另一份”。

账号级 GitHub OIDC Provider 位于 `infra/bootstrap/github-oidc`，环境级 Role 则由 Dev / Prod Terraform Root 创建。

## 9. Dev / Prod 边界

Dev 与 Prod 分别拥有：

- 独立 Terraform Root 与 Remote State Path；
- 独立资源名前缀；
- 独立 Secrets Manager 资源；
- 独立部署控制与 GitHub Environment Scope；
- 独立部署 IAM Roles。

GitHub OIDC 模块还加入了 sibling-environment 边界，目标是让某个环境的 Deployment Role 不去管理另一个环境命名空间下的资源。

不过，这不能被夸大成绝对隔离：部分 AWS Create/List API 本身不支持细粒度 Resource ARN 限制，因此仍然需要依赖 Trust Policy、命名/Tag 规则、审阅后的 Terraform Plan 和 Workflow Control 共同约束。

## 10. Explicit Deny 的实际排障经验

在一次受控 Dev 故障注入中，项目实际验证了两类 IAM 问题：

- 对 `cloudwatch:ListMetrics` 注入显式 Deny 后，healthcheck 即使原策略存在 Allow 也会失败；
- 对 `dynamodb:UpdateItem` 注入显式 Deny 后，巡检主体可以执行成功，但 Jobs 终态无法正常写回。

这里的关键原则是：**Explicit Deny 优先于 Allow。**

正确恢复方式是撤销注入式 Deny，恢复到故障前已知正常的权限状态，而不是为了“修问题”不断添加更大的 Allow。

## 11. 公开仓库安全控制

Public Repo 在运行时 IAM 之外又增加了一层公开安全边界：

- 云部署 Workflow 放在 `.github/deployment-templates/`，默认不启用；
- 公开仓库只启用 CI；
- CI 会拒绝 Terraform State / Plan、真实 `terraform.tfvars`、`.env`、私钥、私有打包产物和常见 Credential Signature；
- 真实 AWS Account ID、Role ARN、State Bucket、Secret 和环境输出被替换或排除。

这是一层“公开发布安全措施”，不能替代运行时 IAM。

## 12. 当前不宣称具备的安全能力

当前项目不宣称：

- 已达到零信任多租户架构；
- 使用纯私有子网的生产级网络；
- 自己实现了完整的自动 Credential Rotation 编排；
- Agent 可以不受限制地自动修复基础设施；
- 可以在任意 AWS Account 中彻底排除所有 Privilege Escalation 路径；
- Public Repo 中的 Deployment Template 可以不经修改直接安全启用。

这个项目更值得展示的地方，是可以直接检查实际 IAM Boundary、解释为什么要这样分层，并能够用真实故障案例说明权限设计和排障方法，而不是把原型包装成已经完全企业级 Harden 的平台。
