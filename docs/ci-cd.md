# CI/CD & GitHub OIDC

[中文](ci-cd.zh-CN.md)

## 1. Public-repository policy

The public repository intentionally keeps **CI active** while storing cloud deployment workflows as **disabled templates**.

```text
.github/
├── workflows/
│   └── ci.yml                  # active
└── deployment-templates/
    ├── cd.yml                  # dev deployment template
    ├── prod.yml                # prod plan template
    ├── prod-apply.yml          # prod apply template
    └── destroy-dev.yml         # dev destroy template
```

This lets reviewers inspect the deployment design without granting the sanitized public repository an active path to a real AWS account.

## 2. Active CI workflow

`OpenClaw CI` runs on:

- pushes to `main`;
- pushes to `ci/**`, `feature/**`, and `fix/**` branches;
- pull requests targeting `main`;
- manual `workflow_dispatch`.

The workflow uses read-only repository permissions:

```yaml
permissions:
  contents: read
```

Checkout also sets `persist-credentials: false`.

Concurrency is grouped by Git ref and stale CI runs are cancelled when a newer run for the same ref starts.

## 3. CI jobs

### Repository Safety

The repository-safety job rejects tracked files matching sensitive deployment artifacts, including:

- Terraform state and backups;
- Terraform saved plan files;
- real `terraform.tfvars`;
- `.env` variants;
- `.pem`, `.key`, and `.secret` files;
- packaged Lambda artifacts used by the private deployment flow.

It also scans tracked content for common credential signatures such as AWS access-key IDs, GitHub tokens, and private-key headers.

This is a guardrail, not a replacement for manual review or dedicated secret-scanning products.

### Terraform dev/prod Validation

The Terraform job pins Terraform `1.15.8` and runs `./infra/scripts/validate.sh`.

The validation script checks formatting and validates four Terraform roots with backends disabled:

```text
infra/bootstrap/remote-state
infra/bootstrap/github-oidc
infra/envs/dev
infra/envs/prod
```

Backend-disabled initialization makes CI suitable for public validation without requiring AWS credentials or access to private Terraform state.

### Python, Shell and Agent Tests

The code-test job:

- creates an isolated Python virtual environment;
- installs `pytest` and runtime Python dependencies;
- compiles Python sources;
- runs tests under `openclaw-agent/tests` and `infra/modules/lambda/tests`;
- runs `bash -n` across shell scripts;
- runs ShellCheck with error severity;
- verifies the checks did not modify tracked files.

At the first stable public release, the suite completed with **58 tests passing**.

### Docker Build

The Docker job builds:

```bash
docker build --tag openclaw-aws-agent:ci ./openclaw-agent
```

This confirms the published Docker context is buildable without needing to push an image or access AWS.

## 4. Why GitHub OIDC is used

The deployment design avoids storing long-lived AWS access keys in GitHub Actions.

Instead, deployment workflows request a GitHub OIDC token:

```yaml
permissions:
  contents: read
  id-token: write
```

`aws-actions/configure-aws-credentials` exchanges that identity for short-lived AWS credentials by assuming a purpose-specific IAM role.

Benefits include:

- no static AWS access key stored as a repository secret;
- short-lived sessions;
- repository / branch / environment-aware trust conditions;
- easier separation between plan, image-delivery, apply, and destroy permissions.

## 5. OIDC bootstrap and trust scope

The account-level GitHub OIDC provider is managed under:

```text
infra/bootstrap/github-oidc
```

Environment Terraform roots then consume the provider ARN instead of attempting to create separate providers per environment.

The GitHub OIDC module derives allowed OIDC subjects from:

- configured repository name;
- configured branch patterns;
- configured GitHub Environment names.

The design also includes an explicit sibling-environment boundary so one environment's deployment role is not intended to manage the other environment's named resources.

## 6. Role separation

The deployment flow separates responsibilities rather than using one broad GitHub-to-AWS role.

### Dev

The dev deployment template uses:

- an **image-delivery role** to authenticate to ECR and build/push the source-commit image;
- a separate **dev deploy role** for Terraform apply.

The image is resolved to a SHA-256 digest before the Terraform deployment.

### Prod

Production uses a stronger two-step control:

- **prod plan role** — promotes the already validated dev image and produces a reviewable saved Terraform plan;
- **prod deploy role** — applies the exact reviewed plan after explicit confirmation.

This keeps the privilege used to prepare a plan separate from the privilege used to change infrastructure.

## 7. Dev deployment template

The disabled `cd.yml` template is designed to run after a successful CI run on `main` or by manual dispatch.

Its sequence is:

```text
resolve source commit
→ checkout exact commit
→ assume image-delivery role
→ build/push immutable image
→ resolve image digest
→ assume dev deploy role
→ terraform plan
→ terraform apply saved plan
→ smoke test
→ upload deployment evidence
```

The template explicitly forces the dev scheduler off during the automated apply unless the deployment design is intentionally changed.

## 8. Production Plan workflow

The disabled `prod.yml` template is manual-only. Inputs include:

- a source image digest already validated in dev;
- whether the three prod schedules should be enabled.

The workflow:

1. assumes the prod Plan role;
2. pulls the dev image by digest;
3. pushes the same artifact into prod ECR;
4. verifies the prod digest is unchanged;
5. creates `prod.tfplan`;
6. renders `prod-plan.txt`;
7. computes `prod-plan.sha256`;
8. writes metadata containing source commit, digest, scheduler state, plan hash, and plan run ID;
9. uploads the artifact for review.

No infrastructure apply occurs in this workflow.

## 9. Production Apply workflow

The disabled `prod-apply.yml` template requires:

- the Run ID of the reviewed Plan workflow;
- explicit confirmation text `APPLY-PROD`.

It then:

1. downloads the exact reviewed plan artifact;
2. validates metadata;
3. checks out the exact source commit used for the plan;
4. validates the plan SHA-256;
5. assumes the prod deploy role;
6. applies the saved plan;
7. runs a prod smoke test;
8. runs an immediate no-drift Terraform plan;
9. uploads deployment evidence.

This design reduces the risk that “the plan that was reviewed” differs from “the change that was applied.”

## 10. Immutable image promotion

Both dev and prod workflows avoid relying on a floating `latest` tag for deployment identity.

Dev builds a source-commit-tagged image and resolves its digest. Prod accepts a digest already validated in dev and promotes that exact image to the prod repository. Terraform consumes the digest, making the deployed artifact explicit and reviewable.

## 11. Evidence and auditability

The deployment templates retain useful evidence artifacts such as:

- human-readable Terraform plan output;
- saved plan checksum;
- deployment metadata;
- smoke-test output;
- immediate drift-check output.

Retention is intentionally bounded rather than permanent. Private evidence may contain environment-specific identifiers and should not be copied blindly into the public repository.

## 12. Public-template activation checklist

Before moving any deployment template into `.github/workflows/`:

1. replace all placeholder account IDs, role ARNs, state bucket names, and repository references;
2. verify the account-level GitHub OIDC provider;
3. review branch and GitHub Environment trust conditions;
4. create/configure the required GitHub Environments and approvals;
5. re-review IAM policies for least privilege;
6. verify the Terraform backend and current state ownership;
7. initialize required secret values outside Git;
8. run active CI successfully;
9. review the first Terraform Plan before any Apply;
10. keep production schedulers disabled unless recurring execution is explicitly intended.

## 13. What the CI/CD design does not claim

The public repository does not claim that its deployment templates are safe to enable unchanged in an arbitrary account. They are architecture and automation evidence derived from the project environment, with real identifiers removed.

Likewise, passing CI proves the published source is internally consistent under the included checks; it does not prove that an arbitrary AWS account is correctly configured or that every external cloud dependency is currently healthy.
