# 重要变更与架构决策

[English](changes-decisions.md)

## 1. 文档目的

本文记录对 OpenClaw-AWS 最终实现产生明显影响的重要变更与架构决策。

这里不试图复制所有历史试验，而是保留当前公开源码中仍然能够看到、并且适合用于代码审阅和面试讲解的关键取舍。

## 2. 决策摘要

| 决策项 | 当前选择 | 主要意义 |
| --- | --- | --- |
| 运行模型 | ECS Fargate 一次性 `RunTask` | 低并发项目不维持长期运行服务 |
| 任务路由 | Step Functions → SQS 优先级队列 → EventBridge Pipes | 将入口、缓冲、路由和执行解耦 |
| 环境隔离 | Dev / Prod 独立 Terraform 根模块和 State 路径 | 降低跨环境误操作风险 |
| GitHub → AWS 身份认证 | GitHub Actions OIDC + AWS 短期凭证 | 不保存长期 AWS Access Key |
| 生产部署 | Plan 与 Apply 分离 | 把“已审阅的确定计划”作为审批边界 |
| ECS 运行权限 | Task Execution Role 与 Task Role 分离 | 区分容器启动权限与应用运行权限 |
| 运维事实来源 | 源 Skill 为事实权威 | 防止模型文本改写实际检查结果 |
| 报告生成 | 固定渲染器 + 受限 LLM 辅助 | 保持报告结构和事实字段可控 |
| ECS Task Definition | `skip_destroy = true` | 普通替换时保留旧 Revision，避免注销依赖 |
| Scheduler | 默认关闭 | 避免无意的周期任务与持续成本 |

## 3. 运行模型：一次性 Fargate Task

### 决策

OpenClaw-AWS 每个运维 Job 使用 ECS Fargate 一次性任务执行，而不是维持一个长期运行的 ECS Service。

### 原因

项目定位是单用户、低并发环境。主要负载是巡检、告警分析和报告生成，而不是持续对外提供请求服务。

一次性任务能够提供：

- Job 级进程隔离；
- Job 与容器执行之间较直观的对应关系；
- 无需维持长期空闲的容器服务；
- 符合当前规模的简单伸缩模型。

### 代价

需要接受容器冷启动和编排延迟，因此不适合作为高频、低延迟交互服务。

## 4. 统一异步 Job 主链路

### 决策

主动请求、定时任务和项目告警最终都进入 Job Receiver，再进入统一生命周期与路由链路。

正常路径为：

```text
入口
→ Job Receiver
→ DynamoDB Jobs
→ Step Functions
→ SQS 优先级队列
→ EventBridge Pipe
→ ECS Fargate
→ Skill
→ Job 终态 / 输出
```

### 原因

统一主链路便于关联和排障。同一个 Job ID 可以从请求受理一直追踪到调度、排队、容器执行和最终状态。

### 背后的经验

历史上的 Jobs 生命周期问题证明：

```text
Step Functions 成功
≠ 实际业务任务完成
```

因此 `RUNNING` 和终态由实际 ECS 运行端负责写回。

## 5. 三类优先级队列与 EventBridge Pipes

### 决策

任务按 `high`、`medium`、`low` 分配到三个 SQS 队列，再由 EventBridge Pipes 消费并启动 Fargate Task。

### 原因

SQS 将消息缓冲与容器执行解耦，并且可以直接通过 SQS 指标观察消息是否进入、是否被消费、是否积压。

链路也自然形成明确的排障边界：

```text
Step Functions → SQS
SQS → Pipe
Pipe → ECS
ECS → Skill
```

### 代价

三条队列表达的是路由类别，不代表跨所有队列存在严格的全局顺序。

## 6. Dev 与 Prod 使用独立 Terraform 根模块

### 决策

`infra/envs/dev` 和 `infra/envs/prod` 使用独立 Root Module、State 路径、资源名前缀、运行密钥和部署控制。

### 原因

两套环境可以复用 Terraform Module，但不应该共享可变 State。

这样既保留代码复用，也让环境边界更加清楚。

### 代价

Dev/Prod 根模块中存在一定配置重复。项目接受这部分重复，以换取部署边界的可读性。

## 7. 使用 GitHub OIDC，而不是长期 AWS Key

### 决策

GitHub Actions 通过 GitHub OIDC Assume AWS Role。

### 原因

部署链路不依赖保存 IAM User 的长期 Access Key。

Role Trust Policy 会限制预期仓库、分支和 GitHub Environment；部署 Role 继续增加项目和环境级约束。

### 代价

OIDC 并不代表 IAM 无需审阅。部分 AWS Create/List API 无法完全按资源 ARN 收敛，因此仍需要：

- Trust Policy；
- 命名和 Tag 约束；
- Dev/Prod 隔离；
- 审阅 Terraform Plan；
- 必要的 Explicit Deny。

## 8. 生产 Plan 与 Apply 分离

### 决策

Prod 的 Terraform Plan 与 Apply 被拆成两个不同阶段。

Prod Plan：

- 接收已在 Dev 验证的镜像 Digest；
- 将同一个 Artifact 推广至 Prod ECR；
- 生成 Saved Terraform Plan；
- 保存 Plan Metadata 和 SHA-256；
- 上传可审阅的 Workflow Artifact。

Prod Apply：

- 必须指定已审阅的 Plan Run ID；
- 校验 Metadata；
- 校验 Saved Plan 哈希；
- Checkout Plan 所记录的源码 Commit；
- 应用同一份已审阅 Plan；
- 执行 Smoke Test 与即时 No-Drift 检查。

### 原因

审批对象是**确定的 Plan Artifact**，而不是 Apply 时重新生成的一份新 Plan。

## 9. 源 Skill 决定事实，LLM 只负责表达

### 决策

源 Skill 输出结构化事实；报告链路只读取经过脱敏后的结果。

模型只允许生成三个表达字段：

```json
{
  "executive_summary": "...",
  "risk_explanation": "...",
  "recommended_actions": ["..."]
}
```

模型不能决定：

- `overall_ok`；
- 源 `status`；
- `severity`；
- checks；
- confirmed facts；
- 最终 Markdown 结构。

### 原因

模型解释不能成为运维事实的来源。

模型失败或输出校验不通过时，系统退回固定模板，不影响源事实。

## 10. 2026-10-13：自动报告链路

### 变更

运行入口扩展为：四个源运维 Skill 完成后，可以自动调用 `aws-report-generation`。

形成：

```text
源 Skill
→ 结构化 JSON
→ 脱敏
→ 固定模板或受限 LLM 摘要
→ 固定中文 Markdown
→ Summary JSON
→ 可选 S3 上传
```

源结果文件不会被覆盖，自动报告使用独立 Report Result 文件。

### 默认行为

```text
OPENCLAW_AUTO_REPORT_ENABLED=true
OPENCLAW_AUTO_REPORT_UPLOAD_S3=true
OPENCLAW_AUTO_REPORT_WRITE_INDEX=false
OPENCLAW_AUTO_REPORT_SUMMARY_MODE=auto
OPENCLAW_AUTO_REPORT_STRICT=false
```

### 设计边界

默认 `OPENCLAW_AUTO_REPORT_STRICT=false`，因此报告链路故障通常不会把已经成功的源 Skill 强行改成失败 Job。

## 11. 保留 ECS Task Definition Revision

### 变更

当前 ECS Task Definition 使用：

```hcl
skip_destroy = true
```

### 原因

一次 Terraform 迁移中，Task Definition 替换暴露出 `ecs:DeregisterTaskDefinition` 权限依赖。

保留旧 Revision 后，普通替换流程不再需要 Terraform 自动注销上一 Revision。

### 代价

旧 Task Definition Revision 会累计，需要单独考虑生命周期治理。

因此该设置是明确的运维取舍，而不是“旧版本永远不需要清理”。

## 12. Scheduler 默认关闭

### 决策

EventBridge Scheduler 默认不启用，只有明确需要时才开启。

### 原因

定时巡检和周报确实有价值，但求职展示和低频测试阶段没有必要持续创建 Job 和费用。

默认行为优先保证“显式启用”，而不是后台一直运行。

## 13. 重要项目演变

| 时间 | 重要变化 |
| --- | --- |
| 2026-07 | 建立 CI 与 Terraform Remote State 基础 |
| 2026-07 | 建立 GitHub OIDC / ECR 交付基础 |
| 2026-07 | 加入 Alert Analysis 与 Report Skill |
| 2026-08 | 修复 Jobs 生命周期缺口并增加终态保护 |
| 2026-08 | 扩展 Dev/Prod 隔离与部署自动化 |
| 2026-10-12 | Dev 综合故障注入：IAM、SQS/Pipes、状态写回 |
| 2026-10-13 | 自动报告链路加入并完成验证 |
| 2026-10-13 | ECS Task Definition 改为 `skip_destroy = true` |
| 2026-10-14 | 脱敏 Public Repo 发布并完成 Public CI 验证 |

这份时间线表示能够核实的实现节点，不等同于项目最初产生想法的日期。

## 14. 个人贡献与工具边界

项目负责人主导需求、范围、服务选择、云端测试、故障处理和验收决策。

代码生成、修改、审阅和文档整理使用了 AI 辅助。

因此这个项目更适合通过以下方面评价：

- 实际架构；
- 是否能够解释设计原因；
- 排障证据；
- 验证结果；
- 工程判断与取舍；

而不是通过“全部代码是否完全手写”来定义项目价值。
