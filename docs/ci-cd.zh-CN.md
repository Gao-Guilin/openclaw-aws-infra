# CI/CD 与 GitHub OIDC

[English](ci-cd.md)

## 1. 公开仓库策略

公开仓库刻意采用：**CI 保持启用，云部署 Workflow 只保留为禁用模板**。

```text
.github/
├── workflows/
│   └── ci.yml                  # 当前启用
└── deployment-templates/
    ├── cd.yml                  # Dev 部署模板
    ├── prod.yml                # Prod Plan 模板
    ├── prod-apply.yml          # Prod Apply 模板
    └── destroy-dev.yml         # Dev Destroy 模板
```

这样招聘者可以直接检查 CI/CD 设计，但脱敏后的公开仓库不会自动获得连接真实 AWS 账号并执行部署的能力。

## 2. 当前启用的 CI

`OpenClaw CI` 会在以下情况执行：

- Push 到 `main`；
- Push 到 `ci/**`、`feature/**`、`fix/**`；
- 向 `main` 发起 Pull Request；
- 手动 `workflow_dispatch`。

Workflow 自身只申请只读仓库权限：

```yaml
permissions:
  contents: read
```

Checkout 同时设置：

```yaml
persist-credentials: false
```

CI 按 Git Ref 做 Concurrency Group；同一 Ref 出现更新的 Run 时，旧 CI 可以被取消，减少无意义重复执行。

## 3. CI Job

### Repository Safety

Repository Safety 会拒绝多类不应公开的受 Git 跟踪文件，例如：

- Terraform State / Backup；
- Saved Terraform Plan；
- 真实 `terraform.tfvars`；
- `.env` 及变体；
- `.pem`、`.key`、`.secret`；
- 私有部署流程中生成的 Lambda Package。

它还会扫描常见凭据签名，例如 AWS Access Key ID、GitHub Token 和 Private Key Header。

这是一层仓库 Guardrail，但不能替代人工检查或专业 Secret Scanning 产品。

### Terraform dev/prod Validation

Terraform Job 固定使用 Terraform `1.15.8`，并执行：

```bash
./infra/scripts/validate.sh
```

脚本在关闭 Backend 的情况下检查格式并校验四个 Terraform Root：

```text
infra/bootstrap/remote-state
infra/bootstrap/github-oidc
infra/envs/dev
infra/envs/prod
```

使用 `-backend=false` 后，公开 CI 不需要真实 AWS Credential 或私有 Terraform State，也可以验证 Terraform 结构和 Provider 配置。

### Python, Shell and Agent Tests

Code Test Job 会：

- 创建独立 Python Virtual Environment；
- 安装 `pytest` 和 Agent 运行依赖；
- 编译 Python Source；
- 运行 `openclaw-agent/tests` 和 `infra/modules/lambda/tests`；
- 对所有 Shell Script 执行 `bash -n`；
- 使用 ShellCheck 做 Error 级别检查；
- 最后确认检查过程没有修改受 Git 跟踪文件。

公开仓库首次稳定版本中，测试结果为 **58 passed**。

### Docker Build

Docker Job 执行：

```bash
docker build --tag openclaw-aws-agent:ci ./openclaw-agent
```

它验证公开的 Docker Context 可以成功构建，不需要 Push Image，也不需要访问 AWS。

## 4. 为什么使用 GitHub OIDC

部署流程不把长期 AWS Access Key 存入 GitHub Actions。

需要 AWS 权限的 Workflow 申请：

```yaml
permissions:
  contents: read
  id-token: write
```

然后通过 `aws-actions/configure-aws-credentials` 使用 GitHub OIDC 身份 Assume 专用 IAM Role，取得短期 AWS Credential。

主要收益包括：

- GitHub 中不保存静态 AWS Access Key；
- Session 生命周期短；
- Trust Policy 可以绑定 Repository、Branch 和 GitHub Environment；
- 更容易拆分 Plan、Image Delivery、Apply 和 Destroy 权限。

## 5. OIDC Bootstrap 与信任范围

账号级 GitHub OIDC Provider 由以下 Root 管理：

```text
infra/bootstrap/github-oidc
```

Dev / Prod 环境只引用 Provider ARN，不再分别创建账号级 Provider。

GitHub OIDC Module 根据以下信息生成允许的 OIDC Subject：

- 配置的 GitHub Repository；
- Branch Pattern；
- GitHub Environment Name。

设计中还包含“Sibling Environment”边界：一个环境的 Deploy Role 不应被用来管理另一个环境命名空间中的资源。

## 6. Role 分离

项目不会用一个宽权限 GitHub → AWS Role 承担所有事情，而是按职责拆分。

### Dev

Dev 部署模板使用：

- **Image Delivery Role**：登录 ECR、构建并 Push 与 Source Commit 对应的镜像；
- 独立的 **Dev Deploy Role**：执行 Terraform Apply。

镜像在进入 Terraform 部署前会先解析成 SHA-256 Digest。

### Prod

Prod 使用更严格的两阶段控制：

- **Prod Plan Role**：Promote 已经在 Dev 验证的镜像，并生成可审阅 Saved Terraform Plan；
- **Prod Deploy Role**：在人工确认后 Apply 已审阅的同一份 Plan。

这样把“生成变更计划”和“真正修改基础设施”所需权限分开。

## 7. Dev 部署模板

禁用的 `cd.yml` 设计为在 `main` CI 成功后执行，也支持人工触发。

主要流程：

```text
确定 Source Commit
→ Checkout 精确 Commit
→ Assume Image Delivery Role
→ Build / Push Immutable Image
→ 解析 Image Digest
→ Assume Dev Deploy Role
→ Terraform Plan
→ Apply Saved Plan
→ Smoke Test
→ 上传 Deployment Evidence
```

自动 Dev Apply 中会显式保持 Scheduler 关闭，除非部署设计被人工修改。

## 8. Prod Plan Workflow

禁用的 `prod.yml` 只支持人工触发，输入包括：

- 已经在 Dev 验证的 Source Image Digest；
- 本次 Release 是否开启三项 Prod Schedule。

Workflow 会：

1. Assume Prod Plan Role；
2. 按 Digest Pull Dev Image；
3. 把同一个 Artifact Push 到 Prod ECR；
4. 检查 Prod Digest 没有改变；
5. 生成 `prod.tfplan`；
6. 生成 `prod-plan.txt`；
7. 计算 `prod-plan.sha256`；
8. 写入 Source Commit、Digest、Scheduler 状态、Plan Hash、Plan Run ID 等 Metadata；
9. 上传 Plan Artifact 供人工审阅。

此 Workflow **不会 Apply 基础设施**。

## 9. Prod Apply Workflow

禁用的 `prod-apply.yml` 要求：

- 提供已经人工审阅的 Plan Workflow Run ID；
- 显式输入 `APPLY-PROD`。

随后会：

1. 下载精确的 Reviewed Plan Artifact；
2. 校验 Metadata；
3. Checkout 生成该 Plan 时使用的 Source Commit；
4. 校验 Saved Plan SHA-256；
5. Assume Prod Deploy Role；
6. Apply Saved Plan；
7. 执行 Prod Smoke Test；
8. 立即再执行一次 Terraform No-Drift 检查；
9. 上传 Deployment Evidence。

这一设计的核心目标是降低：**“人工审阅的 Plan”和“真正被 Apply 的变更”不是同一份内容** 的风险。

## 10. 不可变镜像 Promote

Dev 和 Prod 都不会使用浮动 `latest` 作为部署身份。

Dev 使用 Source Commit 构建镜像并取得 Digest；Prod 接受已经在 Dev 验证的 Digest，然后把相同 Artifact Promote 到 Prod Repository。Terraform 最终消费 Digest，因此实际部署的镜像版本明确、可审阅、可追踪。

## 11. 证据与可审计性

部署模板会保留多类证据，例如：

- 人类可读 Terraform Plan；
- Saved Plan Checksum；
- Deployment Metadata；
- Smoke Test Output；
- 即时 Drift Check Output。

Artifact Retention 有明确期限，而不是永久保存。真实部署证据可能包含环境标识符，因此不能直接原样复制到公开仓库。

## 12. 公开模板启用检查表

任何部署模板从 `.github/deployment-templates/` 移动到 `.github/workflows/` 之前，都应该至少完成：

1. 替换所有占位 Account ID、Role ARN、State Bucket 和 Repository；
2. 确认账号级 GitHub OIDC Provider；
3. 重新审阅 Branch / GitHub Environment Trust Condition；
4. 创建并配置所需 GitHub Environments 与审批规则；
5. 重新按最小权限审阅 IAM Policy；
6. 检查 Terraform Backend 和 State Ownership；
7. 在 Git 外初始化 Secret Value；
8. 确认当前 Active CI 全部成功；
9. 第一次 Apply 前人工审阅 Terraform Plan；
10. 除非明确希望持续执行，否则保持 Prod Scheduler 关闭。

## 13. CI/CD 文档的边界

本公开仓库不会声称这些部署模板可以不经修改直接在任意 AWS 账号启用。它们是从真实项目环境中整理出的架构和自动化证据，其中真实环境标识已经被移除。

同样，CI 成功表示“公开源码通过了仓库中定义的检查”，不代表任何外部 AWS 账号都已经配置正确，也不代表所有云端依赖此刻持续健康。
