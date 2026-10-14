# Validation & Evidence

[中文](validation-evidence.zh-CN.md)

## 1. Evidence model

OpenClaw-AWS separates evidence into four categories:

1. **current public-source validation** — reproducible checks that run against this repository;
2. **historical cloud validation** — private project records from earlier AWS deployment/testing;
3. **incident evidence** — logs, metrics, exit codes, queue state, and lifecycle state captured during troubleshooting;
4. **owner-confirmed acceptance** — validation performed in the original environment where the raw evidence is not fully published.

These categories answer different questions and should not be merged into a stronger claim than the evidence supports.

## 2. Current public CI result

The sanitized public repository was published on 2026-10-14.

The initial public commit exposed a Windows-to-Linux executable-bit issue. After the executable modes were restored, the next CI run completed successfully at commit:

```text
a849ce1eb2f4ccf45b02850a01c94a1bd289a658
fix: restore executable file permissions
```

The successful `OpenClaw CI` run completed all four jobs:

| CI job | Result |
| --- | --- |
| Repository Safety | Passed |
| Terraform dev/prod Validation | Passed |
| Python, Shell and Agent Tests | Passed |
| Docker Build | Passed |

This is the strongest fully public, reproducible evidence currently attached to the repository.

## 3. Repository Safety

The safety job rejects tracked files matching sensitive artifact classes such as:

- Terraform state;
- saved Terraform plans;
- real `terraform.tfvars`;
- `.env` files;
- private-key and secret-style files;
- packaged Lambda ZIP artifacts.

It also scans tracked content for common credential signatures, including AWS access-key patterns, GitHub token patterns, and private-key headers.

This check is intentionally narrow. Passing it does not prove that every possible sensitive string is absent, but it creates a repeatable publication guardrail.

## 4. Terraform validation

The public CI uses Terraform `1.15.8` and runs:

```bash
./infra/scripts/validate.sh
```

The script performs:

```text
terraform fmt -check -diff -recursive
```

and validates four Terraform roots with remote backends disabled:

```text
infra/bootstrap/remote-state
infra/bootstrap/github-oidc
infra/envs/dev
infra/envs/prod
```

Each root must have Terraform files and a provider lock file.

The successful public run finished with:

```text
TERRAFORM_VALIDATION_PASSED
```

This proves syntax/configuration validation for the published Terraform snapshot. It is **not** equivalent to a live AWS `plan` against the original account.

## 5. Python and shell validation

The public CI:

- compiles the Python source;
- runs the Agent and Lambda Python tests;
- validates all Shell scripts with `bash -n`;
- runs ShellCheck at error severity;
- verifies that validation does not modify tracked files.

The successful public run reported:

```text
58 passed
```

The current test suite covers areas including:

- Job Receiver behavior;
- Job lifecycle state handling;
- alert analysis;
- EFS history handling;
- notification dispatch;
- report generation.

The test suite is useful regression evidence, but it does not replace live AWS integration validation.

## 6. Docker build

The CI builds:

```bash
docker build --tag openclaw-aws-agent:ci ./openclaw-agent
```

A successful build proves that the published Dockerfile and checked-in Agent source can be assembled into a container image in the CI environment.

It does not prove that every external runtime dependency or AWS integration is healthy at all times.

## 7. Local reproduction

The public checks can be reproduced locally with the appropriate tools.

### Terraform

```bash
./infra/scripts/validate.sh
```

### Python tests

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

These checks do not require publishing any real Terraform state or secret values.

## 8. Cloud validation paths implemented by the repository

The repository contains operational scripts intended for real AWS validation.

| Script | Intended coverage |
| --- | --- |
| `smoke-test.sh` | operator/API acceptance, Job identity, terminal completion |
| `test-alert.sh` | controlled alarm path and resulting Job/analysis behavior |
| `test-dlq-redrive.sh` | DLQ movement and controlled redrive behavior |
| `verify-scheduler-history.sh` | scheduled-source and historical-record checks |
| `final-regression.sh` | smoke, alert, queue/task residue, Pipe state, drift and alarm checks |

These scripts are stronger than unit tests when executed against a real environment, but the existence of a script is not evidence that every invocation succeeded.

## 9. Historical and private evidence

Private project records state that the following were validated in the original project environment before publication:

- the five task types were invoked through the operator path;
- the production infrastructure and main runtime path were checked after deployment;
- Jobs lifecycle success and controlled failure paths were exercised;
- controlled queue/Pipe recovery behavior was tested;
- the 2026-10-12 fault-injection exercise captured real IAM, SQS, Pipe, ECS, and DynamoDB failure evidence;
- the 2026-10-13 automatic report pipeline was exercised through the Dev runtime.

The public repository intentionally does not publish raw account-specific logs, state files, private screenshots, real ARNs, or secret-bearing outputs.

Therefore these historical records should be treated as supporting project evidence, not as a guarantee of the current health of any live AWS environment.

## 10. Incident evidence standard

For real cloud tests, a useful evidence bundle should correlate the same Job across layers.

Recommended minimum fields:

```text
date/time
environment
source commit
container image digest
request/event
Job ID
Step Functions execution
queue/Pipe state
ECS task / exit code
source Skill result
final Jobs state
report location / hash
```

For notification tests, add a sanitized record of receipt time.

For controlled fault injection, also record:

- the injected fault;
- the original known-good state;
- the recovery action;
- post-recovery validation.

## 11. Evidence boundary examples

### What `202 Accepted` proves

It proves that the API accepted the asynchronous request.

It does not prove that the ECS workload succeeded.

### What Step Functions success proves

It proves that the routing workflow completed its responsibility.

It does not prove that the source Skill completed successfully.

### What `overall_ok = true` proves

It proves the source Skill's own check result according to its contract.

It does not prove that the terminal Jobs record was persisted successfully.

### What CI success proves

It proves the checked-in public snapshot passed the configured static/unit/build checks.

It does not prove that a live AWS deployment has no drift or operational incident.

## 12. Evidence that is intentionally not public

The public repository excludes:

- Terraform state and backup state;
- saved `.tfplan` files;
- real `terraform.tfvars`;
- real AWS account IDs and resource identifiers;
- raw private environment outputs;
- credential-bearing logs;
- unredacted screenshots;
- secret values.

The portfolio goal is to expose enough evidence to review engineering quality without publishing production-identifying material.

## 13. Known evidence gaps

The current public snapshot does not by itself prove:

- a fresh deployment from zero in a separate AWS account;
- long-duration production stability;
- high-concurrency behavior;
- automatic reconciliation after a container dies before writing terminal state;
- that every private historical acceptance artifact is available for public inspection.

These gaps are documented rather than converted into unverified claims.

See [Limitations & Known Constraints](limitations.md) for the corresponding engineering boundaries.
