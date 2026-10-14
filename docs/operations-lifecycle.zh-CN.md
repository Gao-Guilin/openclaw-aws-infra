# 运维流程与任务生命周期

[English](operations-lifecycle.md)

## 1. 运维模型

OpenClaw-AWS 将每一次请求都视为一个可追踪的异步 Job。用户主动请求、定时任务和项目监控告警，最终都会被归一化到同一条任务接收、路由和执行链路。

主链路如下：

```text
API / CloudWatch Alarm / Scheduler
  → Job Receiver Lambda
  → DynamoDB Jobs
  → Step Functions
  → SQS high / medium / low
  → EventBridge Pipes
  → ECS Fargate RunTask
  → Skill 执行
  → 生命周期 / 历史 / 报告 / 通知处理
```

整个设计刻意区分 **请求被受理、路由成功、容器实际执行和最终业务结果**，避免把其中任意一个阶段误认为“任务已经完成”。

## 2. 统一任务入口

Job Receiver 支持三类事件来源：

- API Gateway 用户主动请求；
- EventBridge Scheduler 定时任务；
- 通过 EventBridge 转入的 CloudWatch Alarm State Change。

Receiver 会将不同事件归一化成统一结构，包含：

- `job_id`；
- `task_type`；
- `priority`；
- `target`；
- 来源信息；
- 请求时间；
- 可选告警 Payload。

当前支持的 Task Type：

```text
healthcheck
daily_inspection
cost_inspection
alert_analysis
report_generation
```

支持的优先级为 `high`、`medium`、`low`，当前 Target 为 `aws-account`。

## 3. Job 创建与派发

任务被接受后，Receiver 首先向 DynamoDB 写入：

```text
status = RECEIVED
```

随后启动 Step Functions。如果启动成功，则 Jobs 记录进入：

```text
DISPATCHING
```

如果 Step Functions 启动失败，Receiver 会尽力把 Job 标记为：

```text
START_FAILED
```

因此 API 返回的异步结果只能说明“系统已经受理并开始派发”，不能说明实际业务已经执行完成。

## 4. 去重与重复投递

Scheduler 和 CloudWatch Alarm 事件会构造确定性的 Deduplication Key，用于让同一个逻辑事件在重复投递时得到稳定的 Job Identity。

如果相同事件再次到达，而已有 Job 已经进入实际派发后的状态，Receiver 会返回现有 Job 状态，而不是再启动第二条 Workflow。

如果前一次只创建了 Jobs 记录但没有真正完成派发，则可以重新尝试 Dispatch。

这是事件驱动系统中的一个重要基本假设：消息可能重复投递，组件也可能发生局部失败。

## 5. 优先级路由

Step Functions 将任务路由到三条 SQS：

- high；
- medium；
- low。

队列将接收端与运行端解耦，并在下游暂时不可用时保留消息。

每条 SQS 通过 EventBridge Pipe 连接到 ECS。当前采用“一条消息对应一次 Fargate Task”的模式，因此一个排队 Job 会触发一个一次性容器任务。

三条队列只是优先级通道，不应被解释为跨队列严格全局排序。由于消费时间、启动速度和任务耗时不同，低优先级 Job 仍然可能比某个高优先级 Job 更早结束。

## 6. ECS 运行时启动

容器由 `openclaw-agent/entrypoint.sh` 启动。

在执行 Skill 之前，Entrypoint 会：

- 准备运行目录；
- 渲染 OpenClaw 配置；
- 检查运行时前置条件；
- 根据 `OPENCLAW_TASK_TYPE` 选择 Skill；
- 检查 Skill Runner 是否存在且可执行；
- 尝试把 Jobs 状态更新为 `RUNNING`。

典型生命周期因此为：

```text
RECEIVED → DISPATCHING → RUNNING → SUCCEEDED / FAILED
```

## 7. 生命周期写回

共享模块 `job_status_store.py` 负责 ECS 侧生命周期更新。

它包含几项保护机制：

- `RUNNING` 只能从非终态进入；
- 已经是 `SUCCEEDED` / `FAILED` 的 Job 不允许回退成 `RUNNING`；
- 重复写入同一个目标终态会被幂等接受；
- 最终记录可以保存 Exit Code、完成时间、结果 Hash、源结果状态、`overall_ok`、Failure Stage 和经过长度限制的 Error Message。

DynamoDB Update 使用条件表达式，避免冲突的状态迁移直接覆盖已经落地的终态。

## 8. Source Result 与 Job Lifecycle 是两个概念

项目明确区分：

- **Source Result**：Skill 实际观察到什么、检查结果是什么；
- **Job Lifecycle State**：整个编排与运行链路是否完成，并且状态是否被成功持久化。

例如，一个巡检可以得到 `overall_ok=true`，但如果 Agent 最后无法写入 DynamoDB Terminal Status，控制面的 Jobs 记录仍然可能停留在旧状态。

这一点在故障注入中真实暴露过，也是这个项目最重要的运维经验之一。

## 9. Skill 结束后的处理

源 Skill 返回后，Entrypoint 还可以继续执行多个后处理阶段。

### EFS 脱敏历史

选定的结果会经过脱敏后写入 EFS，用于有限窗口内的报告聚合，而不是长期保存原始敏感 Payload。

### 自动报告

四个运维源 Skill 完成后，Agent 可以自动调用 `aws-report-generation`。报告结果使用独立文件，绝不会覆盖源 Skill Result。

### SNS 通知

如果启用通知，共享 Notification Dispatcher 可以发送任务结果 SNS Notification。

### Terminal Status 写回

Entrypoint 最终计算 Exit Code，并尝试把 Jobs 写成 `SUCCEEDED` 或 `FAILED`。

## 10. Strict 与 Best-effort

运行时将“源任务是否成功”和“后续交付是否成功”分开处理。

主要控制项包括：

- `OPENCLAW_JOB_STATUS_STRICT`；
- `OPENCLAW_EFS_HISTORY_STRICT`；
- `OPENCLAW_AUTO_REPORT_STRICT`；
- `OPENCLAW_SNS_NOTIFY_STRICT`。

公开基线中，自动报告默认为非 Strict。也就是说，LLM 或 Report Pipeline 失败不会直接把一个已经成功的源巡检改成失败 Job。

这样可以避免把“展示层失败”与“事实检查失败”混为一谈，同时报告链路自身仍然会记录错误。

## 11. 完成语义

以下三件事不能画等号：

```text
HTTP 202 Accepted
≠ Step Functions success
≠ final Job success
```

- `202 Accepted`：系统已接受异步请求；
- Step Functions Success：任务验证与路由到队列按设计完成；
- Final Success：ECS Workload 实际执行，并且 Job 正常进入目标终态。

排障时应联合查看：

- Jobs 记录；
- Step Functions Execution；
- SQS / Pipe 状态；
- ECS Task 与 Container Exit Code；
- CloudWatch Logs；
- Source Result / Report Evidence。

## 12. SQS 排障指标

SQS 不适合只看一个指标。更有价值的是组合判断：

```text
NumberOfMessagesSent
NumberOfMessagesReceived
NumberOfMessagesDeleted
ApproximateNumberOfMessagesVisible
ApproximateNumberOfMessagesNotVisible
ApproximateAgeOfOldestMessage
```

例如：消息一直 Visible、`Received=0`、`Deleted=0`，同时 Age 持续上升，通常说明上游已经把消息送进队列，但消费链路没有取走它。

Dev 故障注入中就是通过这组指标把问题定位到停止的 EventBridge Pipe。

## 13. 各层可用证据

| 层级 | 典型证据 |
| --- | --- |
| API 入口 | API Response、Request ID、Authorizer / Receiver Logs |
| Job 控制面 | DynamoDB Jobs Status 与 Timestamp |
| Workflow | Step Functions Execution Status 与 Input/Output |
| Queue | SQS Backlog、Receive/Delete Count、Message Age |
| 消费者 | EventBridge Pipe State 与 Pipe Logs |
| Runtime | ECS Task Status、Stop Reason、Container Exit Code |
| 应用 | Skill JSON Result 与 Agent CloudWatch Logs |
| 交付 | EFS History、S3 Report、Reports Table、SNS Outcome |

比较可靠的排障方式，是先找到“最后一个确认正常的边界”，然后只向下游移动一跳，而不是直接在所有服务中同时猜测。

## 14. 当前生命周期限制

最终 Job 状态主要仍由 ECS Agent 自己写回。

如果容器已经做完了有价值的工作，但最后无法持久化 Terminal Status，Jobs 表就可能变成 Stale State。同样，如果容器被外部直接终止，也不能依靠容器自己执行最终补偿逻辑。

当前项目**没有**一个独立的 Reconciliation Controller，定期将 ECS Reality 与长期停留在 `DISPATCHING` / `RUNNING` 的 Job 做对账。

更偏生产级的后续方案，可以增加独立 Reconciliation Path：发现长期未结束记录、查询 ECS 实际状态，然后进行受控补偿或人工升级。

## 15. 简化运维 Runbook

遇到 Job 卡住或状态不一致时：

1. 确定 Job ID 和当前 Lifecycle State；
2. 确认 Step Functions 是否真的完成派发；
3. 检查对应 SQS 和 EventBridge Pipe；
4. 确认 ECS Task 是否实际启动；
5. 查看 Container Exit Code 和 Agent Logs；
6. 对比 Source Result 与 Jobs Terminal Status；
7. 检查 IAM `AccessDenied`，特别注意 explicit deny；
8. 优先恢复已知正常配置，不要盲目扩大权限；
9. 如果旧容器已经退出，用新 Job 做恢复验证；
10. 保留证据，对无法证明结果的历史 Job 不做“猜测性回填”。
