#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

environment="${1:-dev}"
verify_aws_context
prefix="openclaw-aws-${environment}"

printf 'ECS tasks: '
aws ecs list-tasks --cluster "${prefix}-cluster" --desired-status RUNNING --query 'length(taskArns)' --output text 2>/dev/null || echo 0
printf 'EFS file systems: '
aws efs describe-file-systems --query "length(FileSystems[?Name=='${prefix}-efs'])" --output text
printf 'NAT gateways with prefix tags: '
aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=openclaw-aws Name=tag:Environment,Values="${environment}" --query 'length(NatGateways[?State!=`deleted`])' --output text
printf 'Elastic IPs with project tags: '
aws ec2 describe-addresses --filters Name=tag:Project,Values=openclaw-aws Name=tag:Environment,Values="${environment}" --query 'length(Addresses)' --output text
printf 'RDS instances with prefix: '
aws rds describe-db-instances --query "length(DBInstances[?starts_with(DBInstanceIdentifier, '${prefix}')])" --output text 2>/dev/null || echo 0
