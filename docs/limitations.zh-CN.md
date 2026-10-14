# 已知限制与设计约束

[English](limitations.md)

## 1. 为什么需要这份文档

OpenClaw-AWS 是求职展示项目和可运行的 CloudOps Prototype，不是企业级商业产品。

这份文档主动说明当前工程边界，避免把源码和证据无法支持的能力包装成已经完成的能力。

## 2. 目标运行规模

当前设计面向：

- 单一项目负责人 / Operator；
- 低请求频率；
- 低并发；
- 有边界的 AWS 资源范围；
- 预定义运维 Task Type。

项目没有按高吞吐、多租户服务进行架构设计或压力测试。

## 3. 不提供自主自动修复

当前 Skill 可以：

- 检查；
- 分析；
- 保存状态；
- 生成报告；
- 通知。

但不会无限制地自动执行：

- 删除资源；
- 修改 IAM；
- 重启任意服务；
- 扩缩容任意 Workload；
- 因 CloudWatch Alarm 自动执行 Terraform Apply。

报告中的 Recommended Actions 是给 Operator 的建议，不是系统自动执行命令。

## 4. 网络设计优先考虑成本，不是全私有子网

当前 Fargate 使用 Public Subnet，并分配 Public IP。

项目不创建 NAT Gateway。

这是针对个人低并发环境的成本和复杂度取舍。

因此不能把当前网络描述成强化过的“全 Private Subnet Production Network”。

## 5. 一次性 Fargate Task 存在启动延迟

每个 Job 都会启动 ECS Fargate Task。

优点是隔离和减少长期空闲 Runtime；代价是容器启动和编排延迟。

项目不针对亚秒级实时交互设计。

## 6. 优先级队列不是严格全局排序

`high`、`medium`、`low` 三个 SQS Queue 表达的是任务路由类别。

当前架构不保证跨三个队列、跨全部 Job 的严格 Total Ordering。

## 7. Job 终态没有独立 Reconciliation Service

正常情况下 ECS Agent 负责写入 `RUNNING` 和最终状态。

如果 Task 在终态写回前被强制终止，就可能留下 Stale Job。

当前项目没有一个长期独立运行的对账组件，自动将 ECS Task 结果与 Jobs Table 进行持续比对和补偿。

这也是 Jobs 生命周期故障复盘中明确暴露出的边界。

## 8. 一些辅助步骤默认是 Non-Strict

运行时可以把部分辅助动作作为 Best Effort：

- EFS History 归档；
- 自动 Report Generation；
- SNS Notification。

当配置为 Non-Strict 时，辅助链路失败不一定把已成功的源 Skill 改成失败 Job。

这样可以避免“展示层故障改写源事实”，但 Operator 必须单独阅读 Warning 和 Report Delivery 状态。

## 9. LLM 被严格收敛，但仍然具有非确定性

Report Pipeline 已经限制模型职责：

- 不能修改源事实；
- 只能返回有限 JSON 字段；
- 失败时退回固定 Template。

但自然语言表达本身仍然不是完全确定性的。

因此 LLM 输出不能被单独视为“已确认根因”。

## 10. Runtime Report 当前固定输出简体中文

当前运维 Markdown Report 的固定结构为简体中文。

仓库文档本身提供中英文配套，但 Runtime Renderer 目前不是一个中英文双语报告系统。

## 11. Scheduler 默认关闭

架构支持定时巡检和 Weekly Report，但环境默认关闭 Scheduler。

这样可以避免求职展示和低频测试阶段持续创建 Job 与费用。

如果需要验证 Scheduler，必须明确启用并单独验收。

## 12. Public Deployment Workflow 只是模板

公开仓库将部署 Workflow 放在：

```text
.github/deployment-templates/
```

它们不是 Active GitHub Actions Workflow。

模板包含脱敏 Account Placeholder，启用之前必须完成：

- 替换环境专属 Placeholder；
- 配置 GitHub OIDC / IAM Role；
- 配置 Terraform State；
- 初始化 Secrets；
- 审阅 Trust Policy 和 GitHub Environment 控制。

Public Snapshot 本身不是“开箱即用的生产部署配置”。

## 13. 全新 AWS Account 的零起点复现存在边界

Terraform 和 Deployment 文档描述了基于源码整理出的 Bootstrap 顺序。

原项目在自己的 AWS 环境中完成过建设与验证，但当前脱敏 Public Snapshot 尚未在另一个全新 AWS Account 中从零完整执行到 Production。

这个区别需要明确保留。

## 14. 历史证据不等于实时健康

历史 AWS 验证可以证明某条路径在当时确实工作。

但不能证明：

- 原 AWS 环境今天仍然完全相同；
- 所有依赖今天仍然健康；
- 后续没有发生 Drift。

Public CI 证明的是当前 Repository Snapshot，而不是 Live AWS Uptime。

## 15. ECS Task Definition Revision 会累计

ECS Task Definition 使用：

```hcl
skip_destroy = true
```

这样能够避免普通替换时自动 Deregister 旧 Revision，并减少部署 Role 的权限依赖。

代价是历史 Revision 会不断累积。

当前项目没有实现 Task Definition Revision 的自动清理策略。

## 16. QQBot 属于保留接口，不是主要已验证入口

Agent 仍保留 QQBot 相关配置，但默认关闭。

不能把 QQBot 描述成已经完成验收的主要入口。

当前求职展示重点是：

- Operator/API；
- Alarm Ingress；
- Scheduled Job；
- CloudOps Skills。

## 17. EFS History 只是有限运维历史

EFS 用于保存经过脱敏、大小受限的 Task History，并为 Report Aggregation 提供输入。

它不是：

- 不可篡改 Audit Ledger；
- 长期 Analytics Warehouse；
- Compliance Archive。

Retention 和最大文件大小都属于可配置限制。

## 18. Budget 是成本可见性，不是费用硬上限

AWS Budgets 能提供成本观察和通知。

Budget Threshold 不会自动阻止 AWS 服务继续产生费用。

真正的成本控制仍然依赖：

- 架构选择；
- Scheduler；
- 资源清理；
- Operator 管理。

## 19. Public Sanitization 不能代替 Secret Management

Public Repo CI 会检查常见 Secret Pattern，并排除已知不应发布的私有 Artifact。

但：

- Regex Scan 不可能数学意义上覆盖所有 Secret；
- 后续修改仍可能误提交敏感信息；
- 部署仍应依赖 Secrets Manager、OIDC、私有 Variable 和 Environment Controls。

脱敏扫描是最后一道 Guardrail，不是 Secret Management System 本身。

## 20. 明确不宣称的能力

当前项目不宣称：

- Enterprise SRE Maturity；
- 自动 Incident Remediation；
- Multi-Region HA；
- Multi-Tenant Isolation；
- Kubernetes Orchestration；
- Formal Compliance Certification；
- 完整 Disaster Recovery；
- 高并发性能验证。

这些属于当前 Portfolio Scope 之外的能力，而不是需要隐藏的问题。

## 21. 后续最高价值改进

如果项目未来继续开发，优先价值较高的改进包括：

1. 独立 Job State Reconciliation；
2. 按 Public Documentation 在全新 Account 做完整部署演练；
3. ECS Task Definition Revision 自动 Retention；
4. 更完整的 End-to-End Evidence Package；
5. 增加真实 AWS Failure Boundary 的 Integration Tests；
6. 可选中英文 Runtime Report。

这些是未来增强项，不是理解当前实现的前置条件。
