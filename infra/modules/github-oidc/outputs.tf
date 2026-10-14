output "oidc_provider_arn" {
  description = "ARN of the account-level GitHub Actions OIDC provider shared by dev and prod."
  value       = var.oidc_provider_arn
}

output "provider_arn" {
  description = "Compatibility alias for the shared GitHub Actions OIDC provider ARN."
  value       = var.oidc_provider_arn
}

output "cd_role_name" {
  description = "Name of the environment-scoped GitHub Actions image delivery role."
  value       = aws_iam_role.cd.name
}

output "cd_role_arn" {
  description = "ARN of the environment-scoped GitHub Actions image delivery role."
  value       = aws_iam_role.cd.arn
}

output "cd_policy_arn" {
  description = "ARN of the GitHub Actions image delivery policy."
  value       = aws_iam_policy.cd.arn
}

output "plan_role_name" {
  description = "Name of the read-only Terraform Plan role."
  value       = try(aws_iam_role.plan[0].name, null)
}

output "plan_role_arn" {
  description = "ARN of the read-only Terraform Plan role."
  value       = try(aws_iam_role.plan[0].arn, null)
}

output "plan_policy_arn" {
  description = "ARN of the custom Terraform Plan policy."
  value       = try(aws_iam_policy.plan[0].arn, null)
}

output "deploy_role_name" {
  description = "Name of the approved Terraform Apply role."
  value       = try(aws_iam_role.deploy[0].name, null)
}

output "deploy_role_arn" {
  description = "ARN of the approved Terraform Apply role."
  value       = try(aws_iam_role.deploy[0].arn, null)
}

output "deploy_policy_arn" {
  description = "Compatibility output for the deploy control policy ARN."
  value       = try(aws_iam_policy.deploy_control[0].arn, null)
}

output "deploy_policy_arns" {
  description = "ARNs of all policies attached to the approved Terraform Apply role."
  value = var.terraform_deploy_enabled ? [
    aws_iam_policy.deploy_control[0].arn,
    aws_iam_policy.deploy_compute[0].arn,
    aws_iam_policy.deploy_data[0].arn
  ] : []
}

output "allowed_subjects" {
  description = "Compatibility output containing subjects permitted to assume the image-delivery role."
  value       = local.cd_allowed_subjects
}

output "plan_allowed_subjects" {
  description = "GitHub branch subjects permitted to assume the Terraform Plan role."
  value       = local.branch_subjects
}

output "deploy_allowed_subjects" {
  description = "GitHub Environment subjects permitted to assume the Terraform Apply role."
  value       = local.deploy_environment_subjects
}
