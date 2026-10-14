# 验证结果与项目证据

[English](validation-evidence.md)

## 1. 证据模型

OpenClaw-AWS 将证据分成四类：

1. **当前 Public Repo 可复现验证**：直接针对本公开仓库执行；
2. **历史云端验证**：原 AWS 环境中留下的私有项目记录；
3. **Incident 证据**：排障期间的日志、指标、退出码、队列状态和生命周期状态；
4. **项目负责人已完成的验收确认**：实际验证已经执行，但原始材料没有全部公开。

这四类证据回答的问题不同，不能互相混用，也不能组合成比原证据更强的结论。

## 2. 当前 Public CI

脱敏 Public Repo 于 2026-10-14 发布。

第一次 Public Commit 暴露了 Windows → Linux 文件执行权限位的问题。恢复 Executable Bit 后，下一轮 CI 在以下 Commit 完整通过：

```text
a849ce1eb2f4ccf45b02850a01c94a1bd289a658
fix: restore executable file permissions
```

成功的 `OpenClaw CI` 包含四个 Job：

| CI Job | 结果 |
| --- | --- |
| Repository Safety | 通过 |
| Terraform dev/prod Validation | 通过 |
| Python, Shell and Agent Tests | 通过 |
| Docker Build | 通过 |

这是当前仓库中最强的一组**完全公开、可以重新执行**的证据。

## 3. Repository Safety

仓库安全检查会拒绝典型不应提交的文件，例如：

- Terraform State；
- Saved Terraform Plan；
- 真实 `terraform.tfvars`；
- `.env`；
- Private Key / Secret 类型文件；
- 打包后的 Lambda ZIP。

同时扫描常见 Credential Signature，包括：

- AWS Access Key 形式；
- GitHub Token 形式；
- Private Key Header。

这个检查有明确边界：通过扫描不代表世界上所有敏感信息模式都被证明不存在，但它提供了可重复执行的公开仓库保护。

## 4. Terraform Validation

Public CI 当前使用 Terraform `1.15.8`，执行：

```bash
./infra/scripts/validate.sh
```

脚本先运行：

```text
terraform fmt -check -diff -recursive
```

随后在关闭 Remote Backend 的情况下验证四个 Terraform Root：

```text
infra/bootstrap/remote-state
infra/bootstrap/github-oidc
infra/envs/dev
infra/envs/prod
```

每个 Root 都必须包含 Terraform 文件与 Provider Lock File。

Public CI 的成功日志最终输出：

```text
TERRAFORM_VALIDATION_PASSED
```

这证明当前公开 Terraform Snapshot 可以通过语法和配置校验。

它**不等价于**针对原 AWS 账号执行实时 `terraform plan`。

## 5. Python 与 Shell 验证

Public CI 会：

- 编译 Python；
- 执行 Agent 与 Lambda Python 测试；
- 对所有 Shell 脚本执行 `bash -n`；
- 执行 ShellCheck Error 级检查；
- 检查验证流程是否意外修改 Git Tracked Files。

当前成功结果为：

```text
58 passed
```

测试覆盖内容包括：

- Job Receiver；
- Job 生命周期状态；
- Alert Analysis；
- EFS History；
- Notification Dispatcher；
- Report Generation。

这些测试属于重要回归证据，但不能代替真实 AWS 集成测试。

## 6. Docker Build

CI 执行：

```bash
docker build --tag openclaw-aws-agent:ci ./openclaw-agent
```

成功 Build 说明公开的 Dockerfile 和 Agent 源码能够在 CI 环境中组成容器镜像。

它不能证明所有外部依赖和 AWS 集成在任何时间都处于正常状态。

## 7. 本地复现

具备对应工具后，可以在本地复现公开检查。

### Terraform

```bash
./infra/scripts/validate.sh
```

### Python Tests

```bash
python3 -m venv .venv
.venv/bin/pip install pytest -r openclaw-agent/requirements.txt
.venv/bin/python -m pytest -q \
  openclaw-agent/tests \
  infra/modules/lambda/tests
```

### Docker

```bash
docker build -t openclaw-aws-agent:local ./openclaw-agent
```

这些检查不要求把真实 Terraform State 或 Secret 上传到仓库。

## 8. 仓库中的云端验证入口

仓库保留了真实 AWS 环境验证脚本。

| 脚本 | 主要验证范围 |
| --- | --- |
| `smoke-test.sh` | 主动/API 受理、Job ID、终态 |
| `test-alert.sh` | 受控告警链路及 Job/分析结果 |
| `test-dlq-redrive.sh` | DLQ 进入和受控 Redrive |
| `verify-scheduler-history.sh` | Scheduler 来源和历史记录 |
| `final-regression.sh` | Smoke、告警、队列/Task 残留、Pipe、Drift、Alarm |

当这些脚本在真实环境执行时，其证据强度高于本地 Unit Test。

但是“存在脚本”本身不等于“每一次真实运行均已成功”。

## 9. 历史与私有证据

原项目的私有记录表明，在转 Public Repo 之前曾完成以下验证：

- 5 类 Task 均通过主动入口实际调用；
- Prod 基础设施与主要运行链路在部署后做过检查；
- Jobs 生命周期成功和受控失败路径做过实际验证；
- Queue / Pipe 恢复机制做过受控演练；
- 2026-10-12 综合故障演练保留了 IAM、SQS、Pipe、ECS、DynamoDB 等真实服务证据；
- 2026-10-13 自动报告链路在 Dev Runtime 中做过实际验证。

Public Repo 不公开账号级原始日志、State、真实 ARN、原始截图和包含私有信息的输出。

因此这些历史材料可以作为项目佐证，但不能被写成“当前某个在线 AWS 环境持续健康”的保证。

## 10. Incident 证据标准

真实云端验证最好用同一个 Job ID 串起多层证据。

建议至少保留：

```text
日期 / 时间
环境
源码 Commit
容器镜像 Digest
请求 / Event
Job ID
Step Functions Execution
Queue / Pipe 状态
ECS Task / Exit Code
源 Skill Result
最终 Jobs State
Report 位置 / Hash
```

通知类验证再保留脱敏后的接收时间。

故障注入还应额外记录：

- 注入了什么；
- 原 Known-Good 状态；
- 恢复动作；
- 恢复后验证结果。

## 11. 典型证据边界

### `202 Accepted` 能证明什么

证明 API 已经接受异步请求。

不能证明 ECS Workload 已成功执行。

### Step Functions Success 能证明什么

证明路由 Workflow 完成了它负责的部分。

不能证明源 Skill 成功。

### `overall_ok = true` 能证明什么

证明源 Skill 按自身 Contract 判断检查通过。

不能证明 Jobs 终态写回一定成功。

### CI Success 能证明什么

证明当前 Git 公开 Snapshot 通过所配置的静态、单测和构建检查。

不能证明实时 AWS 环境无 Drift、无 Incident。

## 12. 明确不公开的证据

Public Repo 不包含：

- Terraform State / Backup State；
- Saved `.tfplan`；
- 真实 `terraform.tfvars`；
- 真实 AWS Account ID 和唯一 Resource ID；
- 原环境私有 Output；
- 包含凭据的日志；
- 未脱敏截图；
- Secret Value。

目标是提供足够的工程可审阅性，同时不泄露真实云环境身份信息。

## 13. 当前证据缺口

当前 Public Snapshot 本身不能证明：

- 在另一个全新 AWS Account 从零完整部署已经复现；
- 长周期 Prod 稳定性；
- 高并发行为；
- 容器在终态写回前意外消失时存在独立自动补偿；
- 所有历史验收原始材料都适合公开查看。

这些缺口应被明确记录，而不是写成未经验证的成果。

对应工程边界见 [已知限制与设计约束](limitations.zh-CN.md)。
