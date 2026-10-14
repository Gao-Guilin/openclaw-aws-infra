# 故障处理与排障记录

[English](incidents.md)

## 1. 文档目的

本文整理 OpenClaw-AWS 中最有代表性的排障记录，用于展示系统在真实链路中的故障边界和处理方法。

这里**不会**直接公开私有原始日志。真实 AWS Account ID、完整 Resource ARN、Job ID、截图和私有环境细节都被省略。公开版保留的是：故障机制、定位路径、恢复逻辑和工程经验。

重点保留两类记录：

1. 2026 年 8 月发现的 Jobs Lifecycle 缺陷：历史 Job 长期停留在 `DISPATCHING`；
2. 2026-10-12 Dev 综合故障注入：同时覆盖运行时 IAM、队列消费和终态写回。

## 2. 记录 A —— Jobs 长期停留在 DISPATCHING

**类型：** 实现缺陷 / 生命周期缺口
**发现时间：** 2026-08-02
**公开事件编号：** `OC-AWS-JOBS-001`

### 现象

审计发现多条历史 Job 长期停留在：

```text
DISPATCHING
```

对应 Step Functions 已经成功，容器也存在应用日志，但 Jobs 表没有体现真实运行结束状态。

### 初步边界确认

排查确认：

- Receiver 能正常创建 Job 并写 Dispatch 状态；
- Step Functions 能正常把工作路由出去；
- Task Role 当时具备预期 DynamoDB 权限；
- 在被审阅的运行路径中没有找到对应 AccessDenied。

因此可以排除“单纯缺少 DynamoDB Permission”作为原始根因。

### 根因

真正的问题是生命周期契约不完整。

Job Receiver 负责创建记录和 Dispatch State，Step Functions 负责投递队列，但当时容器端并没有在业务执行前后写：

- `RUNNING`；
- `SUCCEEDED` / `FAILED`。

因此：

```text
Step Functions Success
≠ Workload Completion
```

即使容器真实运行过，Jobs 记录也可能一直停在 `DISPATCHING`。

### 修复

Agent Runtime 增加：

- 共享 Jobs Lifecycle Helper；
- Skill 开始前写 `RUNNING`；
- Skill 结束后写 `SUCCEEDED` / `FAILED`；
- Preflight Failure 尽力写回；
- Terminal State Regression Protection；
- 同终态重复写的幂等处理；
- Exit Code、Result Status、Result Hash、Failure Stage 等有限元数据。

### 验证

修复后验证了成功路径和受控失败路径。终态回退被阻止，同一个终态的重复写入可以安全处理。

### 历史边界

那些已经失去原始 Container Exit Evidence 的旧 Stale Record 没有被强行回填为成功。

这是非常重要的证据原则：**无法证明的历史结果，不应该为了让数据“好看”而被改写。**

### 经验

Workflow Engine 的 Success 不是业务完成信号。真正可靠的 Job 证据链，需要用同一个 Job ID 串起入口、路由、容器执行、Exit Status、Source Result 和最终 Lifecycle Record。

## 3. 记录 B —— 2026-10-12 Dev 综合故障注入

**类型：** 受控 Fault Injection / 排障演练
**环境：** 仅 Dev
**区域：** `ap-northeast-1`
**Prod 影响：** 无

本次同时注入 3 个互相独立的故障，分别落在 High / Medium / Low Priority。

| Priority | Task | 主要现象 | Root Cause |
| --- | --- | --- | --- |
| High | `healthcheck` | ECS 已启动，但 Container Exit Code = 1 | `cloudwatch:ListMetrics` 被 IAM Explicit Deny |
| Medium | `daily_inspection` | 消息停在 SQS，未产生 ECS Task | 对应 EventBridge Pipe = `STOPPED` |
| Low | `cost_inspection` | Source Check 成功，但 Jobs 不进入终态 | `dynamodb:UpdateItem` 被 IAM Explicit Deny |

这次演练的目的不是展示自动修复，而是验证能不能依靠真实 Service Evidence 把不同层面的故障拆开。

## 4. High —— Runtime API 被拒绝

### 现象

High Priority Healthcheck 已经进入 ECS，Container 能启动，但最终 Exit Code = `1`。

Agent Logs 中出现：

```text
cloudwatch:ListMetrics
```

对应 AWS Authorization Error，并明确指出存在 Identity-based **explicit deny**。

### 定位

故障边界可以划为：

```text
ECS Task Launch        正常
Container Startup      正常
CloudWatch API Call    DENIED
Skill Result           FAILED
```

原 Task Policy 中已经存在该 Action 的 Allow，但注入的 Explicit Deny 优先级更高。

### 恢复原则

正确做法是删除注入式 Deny，恢复故障前已知正常的 Role State。

再添加一个更大的 Allow 既不能覆盖 Explicit Deny，也会让权限变得更难解释。

旧 Container 已经退出，所以 IAM 恢复后不能期待它自动“继续跑”。最终验证应重新提交一个**新的** Healthcheck Job。

## 5. Medium —— Queue Consumer 被停止

### 现象

Medium Priority Job 已经进入 SQS，但没有对应 ECS Task。

SQS 指标组合：

```text
Sent = 1
Visible = 1
Received = 0
Deleted = 0
NotVisible = 0
AgeOfOldestMessage 持续上升
```

对应 EventBridge Pipe 为 `STOPPED`。

### 定位

链路边界很清楚：

```text
Step Functions → SQS       正常
SQS → EventBridge Pipe     中断
Pipe → ECS                 未到达
```

这不是 ECS RunTask 问题，也不是上游 Dispatch 问题。

### 恢复原则

SQS 中原消息保留，不做人工 Receive/Delete。

将 Pipe 恢复成 `RUNNING` 后，排队消息可以继续沿正常消费者路径被处理。此前对同一机制做过独立可逆演练，已实际看到 Backlog 下降并成功进入下游。

需要注意：这个独立演练只能作为同机制旁证，不和 2026-10-12 当天的现场 Evidence 混写。

## 6. Low —— Workload 成功，但 Lifecycle Persistence 失败

### 现象

Low Priority Cost Inspection 的源任务已经完成，并得到：

```text
overall_ok = true
```

ECS Container 正常退出，但 Jobs 没有进入预期终态。

Lifecycle 写回日志出现：

```text
dynamodb:UpdateItem
```

的 Authorization Failure，同样明确指向 Explicit Deny。

### 定位

关键区别是：

```text
Source Workload Result      SUCCEEDED
Terminal State Persistence  FAILED
```

这是控制面状态一致性问题，不是 Source Inspection 自身失败。

### 恢复原则

撤销注入式 Deny。由于旧 Container 已结束，所以恢复验证必须使用新的 Job，确认：

- Source Workload 仍然成功；
- `UpdateItem` 不再 AccessDenied；
- Jobs 可以正常进入 `SUCCEEDED` 或 `FAILED`。

如果要修旧 Stale Record，必须先对齐真实 ECS Outcome，不能假设所有 Stale Job 都是成功的。

## 7. 本次演练使用的排障方法

最有复用价值的方法，是把架构拆成连续边界，每次只回答一个问题：

```text
Request 是否被接受？
→ Job Record 是否创建？
→ Step Functions 是否完成 Dispatch？
→ SQS 是否收到消息？
→ Pipe 是否消费？
→ ECS Task 是否启动？
→ Container Exit Code 是多少？
→ Source Skill 实际输出什么？
→ Jobs Terminal State 是否成功持久化？
```

这样可以避免把三个互相独立的问题统统归结为“某个 AWS 服务坏了”。

## 8. Evidence-first 原则

项目从这几次排障中沉淀出一些很实用的规则：

- **Explicit Deny > Allow。** 不要用扩大 Allow 去“修” Explicit Deny。
- **SQS 要看指标组合。** 仅看 Sent 不能证明已经被消费。
- **队列消息可以在 Consumer 恢复后继续处理。** 已经退出的 Container 不会自动复活。
- **Source Result 和 Lifecycle State 是两个事实。** Workload 成功，也可能出现控制面 Stale State。
- **配置恢复应恢复到故障前已知状态。** 不要把排障演练变成无关架构重构。
- **没有保存下来的验证就不要写成已完成。** 例如没有保留 No-drift Plan，就不能把它包装成已有证据。

## 9. 故障演练安全边界

2026-10-12 的范围固定在 Dev。

恢复过程明确避免：

- 删除业务数据；
- 删除 SQS / DynamoDB / EFS / ECS 资源；
- 修改 Terraform State；
- 用 Terraform Destroy/Apply 制造故障；
- 把修改应用源代码作为第一恢复动作；
- 影响 Prod。

目标是定位和可逆恢复，而不是做破坏性 Chaos Test。

## 10. 这些故障如何反向影响设计

这些 Incident 直接推动了最终实现和文档中的多个设计：

- Jobs Lifecycle Write 成为 Agent Runtime 的正式职责；
- 增加 Terminal-state Regression Protection 与 Idempotent Update；
- 文档明确写出 `202 Accepted != task success`；
- 文档明确写出 `Step Functions success != Job success`；
- SQS / Pipe 排障与 ECS Runtime 排障被作为不同层处理；
- IAM 排障中特别关注 Explicit Deny；
- 独立 Stale-job Reconciliation 仍未实现，因此作为已知限制公开，而不是隐藏。

## 11. 当前剩余运维风险

最终 Job State 仍然主要依赖 ECS Agent 自己写回。

项目目前没有独立 Reconciliation Service。更偏生产级的后续方案，可以定期扫描长期停留在非终态的 Jobs，和 ECS Task Reality 做关联，再执行受控补偿或交给人工处理。

这个限制会保留在公开文档中，因为它是当前系统真实的工程权衡和 Failure Model 的一部分。
