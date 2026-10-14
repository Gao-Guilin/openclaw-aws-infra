# Skills 与自动报告链路

[English](skills-reporting.md)

## 1. Skill 模型

OpenClaw-AWS 的核心并不是一个开放的 Shell，也不是一个拥有通用云管理员权限的 Agent。运行时工作被拆成少量预定义 **CloudOps Skills**，每个 Skill 都有明确的输入、输出、AWS 调用范围和安全边界。

当前 5 个 Skill：

| Task Type | Skill | 主要职责 |
| --- | --- | --- |
| `healthcheck` | `aws-task-healthcheck` | 验证运行时前置条件、云身份和基础 CloudWatch 可见性。 |
| `daily_inspection` | `aws-daily-inspection` | 巡检项目健康状态、告警、日志和选定资源。 |
| `cost_inspection` | `aws-cost-inspection` | 识别明显成本风险和资源残留风险。 |
| `alert_analysis` | `aws-alert-analysis` | 归一化告警，并拆分事实、可能原因、未知项和下一步检查。 |
| `report_generation` | `aws-report-generation` | 将脱敏后的结构化结果转换成人类和机器可读的报告。 |

## 2. Source Skill 是事实源

前四个 Skill 被视为 **Source Skills**。它们输出的结构化 JSON 是运维事实的权威来源。

Report Generation 不允许修改源结果中的：

- `overall_ok`；
- `status`；
- `severity`；
- `checks`；
- 已确认事实和证据。

这个边界很重要：LLM 在这里是表达辅助，而不是 AWS 实际状态的事实来源。

## 3. Healthcheck

`aws-task-healthcheck` 用于确认 Agent 容器是否具备执行基础 CloudOps 工作的条件。

主要检查：

- 运行目录和渲染后的配置；
- Prompt / Workspace 是否存在；
- OpenClaw CLI 是否可用；
- AWS Region；
- STS Caller Identity；
- 基础 CloudWatch Metric 可见性；
- 必需 Secret 是否存在，但不打印真实 Secret Value。

核心云调用保持只读；Mandatory Check 失败会返回非 0 Exit Code。

## 4. Daily Inspection

`aws-daily-inspection` 执行轻量级只读环境巡检。

可以检查：

- Caller Identity 与 Region；
- ECS Task Metadata；
- CloudWatch Metric 与 Alarm Summary；
- CloudWatch Logs Retention；
- 在提供资源标识后检查指定 S3、DynamoDB、SQS、SNS、EFS、ECS 资源。

如果某项 IAM 权限不足，会被明确记录到 `permission_limitations`，而不是被隐藏。Strict Mode 可以把部分读取失败提升为 Task Failure；Non-strict Mode 更适合不完整的早期环境。

## 5. Cost Inspection

`aws-cost-inspection` 的目标是发现明显费用和清理风险，而不是精确计算最终 AWS Bill。

典型检查包括：

- Cost Explorer / Budgets 可见性；
- NAT Gateway 是否存在；
- EFS 是否存在及规模；
- Log Group 是否缺少 Retention；
- DynamoDB 是否使用 Provisioned Capacity；
- SQS Backlog；
- SNS 是否存在未确认或缺失订阅；
- ECS Cluster Task / Service 数量。

Skill 会输出 `cost_risks`、权限限制和建议，但不会自动修改基础设施。

## 6. Alert Analysis

`aws-alert-analysis` 可以处理多种事件形式，例如：

- EventBridge CloudWatch Alarm State Change；
- 经典 CloudWatch Alarm Notification，包括 SNS 包装格式；
- ECS Task State Change；
- 通用 Agent Failure Payload；
- 通用 Alert Object。

输出中刻意拆分：

```text
confirmed_facts
likely_causes
unknowns
recommended_next_checks
```

`likely_causes` 只能作为假设，不能被当作已经确认的 Root Cause。该 Skill 不执行 Remediation。

## 7. 统一报告链路

自动报告主流程：

```text
Source Skill
  → Structured Source JSON
  → Sanitization
  → Summary Routing
       → Deterministic Template
       或
       → 受约束 OpenClaw + DeepSeek Interpretation
  → 固定 Markdown Renderer
  → Summary JSON
  → 可选 S3 Upload
  → 可选 DynamoDB Reports Index
```

Source Result 与 Report Result 始终分开保存。自动报告使用独立结果文件：

```text
/tmp/openclaw-report-results/<job-id>.json
```

不会覆盖原始 Source Result。

## 8. LLM 的严格职责边界

使用 LLM 时，模型只允许返回三个表达层字段：

```json
{
  "executive_summary": "...",
  "risk_explanation": "...",
  "recommended_actions": ["...", "..."]
}
```

Prompt 明确禁止模型：

- 调用 Tool；
- 读取其他文件；
- 访问 AWS；
- 执行命令；
- 改写源 `overall_ok`、`status`、`severity`、`checks` 和 confirmed facts；
- 把 `likely_causes` 写成已确认根因；
- 在证据不足时补造事实；
- 推荐自动修改基础设施。

如果模型调用失败或输出校验失败，Report Generation 会回退到 Deterministic Template。

## 9. Summary Routing Policy

在 `OPENCLAW_REPORT_SUMMARY_MODE=auto` 下，会根据源结果选择 Template、Flash 或 Pro。

当前策略大致为：

| Source | 干净 / 简单结果 | Warning / 普通问题 | 更复杂 / 更高 Severity |
| --- | --- | --- | --- |
| Healthcheck | Template | Flash | Flash |
| Daily Inspection | Template | Flash | Flash |
| Cost Inspection | Template | Flash | 多风险/复杂结果使用 Pro |
| Alert Analysis | 简单 info/low 使用 Template | medium 使用 Flash | high/critical 使用 Pro |
| EFS Aggregate Report | — | — | Pro |

也支持手动指定：

```text
template
llm_flash
llm_pro
auto
```

## 10. 脱敏边界

在进入模型和报告交付之前，Pipeline 会只提供允许字段组成的 Sanitized View。

Summarizer 只能看到解释运维结果真正需要的字段。受支持的敏感 Key 和常见 Secret Pattern 会在渲染、模型输入、持久化和 stdout 输出前被脱敏。

原始 Alert Payload 也不会被原样直接写入 EFS History。

## 11. 固定中文 Markdown 结构

最终人类可读报告的结构是确定性的：

1. 检查结论
2. 本次检查内容
3. 检查结果
4. 发现的问题、警告与限制
5. 风险说明
6. 建议
7. 任务信息
8. 结构化证据摘要

LLM 不控制 Markdown Layout，因此 Template Mode 和 LLM Mode 的报告结构保持一致。

## 12. 报告 Artifact

报告链路主要生成两类文件：

```text
<source-skill>_<YYYYMMDDTHHMMSSZ>_<job-id>.md
<source-skill>_<YYYYMMDDTHHMMSSZ>_<job-id>.summary.json
```

启用 S3 Upload 后，当前目录结构为：

```text
reports/<environment>/<source-skill>/<YYYY>/<MM>/<DD>/
```

Markdown 用于人工阅读；`.summary.json` 用于机器读取、索引或后续自动化。

## 13. 可选 DynamoDB Reports Index

自动 Post-task 路径中，Report Index 默认关闭。

启用后，Reports Table 可以记录：

- Report / Job Identity；
- Source Task / Skill；
- Source Health Result；
- Report Status；
- Summary Mode / Model；
- Count 与 Hash；
- S3 Artifact Location。

这样可以把大型可读内容留在 S3，同时在 DynamoDB 中保存可查询元数据。

## 14. EFS History 聚合

运行时可以把脱敏后的短期任务历史保存到 EFS。没有显式输入时，`aws-report-generation` 可以聚合最近的历史记录。

关键限制包括：

- 允许进入历史的 Task Type；
- Retention Window；
- 单文件最大大小；
- Report Lookback Window；
- 单次报告最多消费多少历史记录。

公开基线刻意设置有限 Lookback 和 Item Count，不把 EFS 当成无限容量的长期分析数据库。

## 15. 自动报告默认值

当前运行时默认：

```text
OPENCLAW_AUTO_REPORT_ENABLED=true
OPENCLAW_AUTO_REPORT_UPLOAD_S3=true
OPENCLAW_AUTO_REPORT_WRITE_INDEX=false
OPENCLAW_AUTO_REPORT_SUMMARY_MODE=auto
OPENCLAW_AUTO_REPORT_STRICT=false
OPENCLAW_REPORT_LLM_TIMEOUT_SECONDS=120
```

`STRICT=false` 是有意选择：展示层失败不应该自动把一个已经成功的 Source Skill 改写成失败。

## 16. Failure Semantics

报告链路区分：

- Source Skill Failure；
- LLM Summary Failure；
- Markdown / Summary Generation Failure；
- S3 Delivery Failure；
- 可选 Reports Index Failure。

LLM 失败时使用 Deterministic Fallback。Report Delivery 问题记录为 Report Pipeline 自身错误；在 Non-strict 模式下，它不会制造一个假的 Source Failure。

## 17. 为什么采用这种设计

项目需要让结构化运维结果变得容易阅读，但如果允许自由模型直接重写系统事实，会显著降低可审计性。

因此最终设计采用：

```text
Deterministic Code 负责 Facts / Evidence
+ Bounded LLM 负责 Explanation / Wording
+ Deterministic Renderer 负责 Report Structure
```

这样既能展示 LLM 集成，又不会让云状态“事实”依赖不受约束的 Model Output。

## 18. 当前边界

Skills / Report System 不宣称：

- 可以自主修复基础设施；
- 提供任意 Shell 命令作为用户功能；
- 所有 Permission Limitation 都能自动解决；
- Model Recommendation 是可以直接执行的变更指令；
- EFS History 是永久证据归档；
- LLM 可以覆盖缺失证据，或把假设自动升级成事实。
