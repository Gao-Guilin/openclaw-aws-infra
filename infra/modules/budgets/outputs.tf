output "budget_name" {
  description = "Name of the monthly AWS cost budget."
  value       = aws_budgets_budget.monthly_account_cost.name
}

output "budget_id" {
  description = "Terraform resource ID of the monthly AWS cost budget."
  value       = aws_budgets_budget.monthly_account_cost.id
}

output "budget_arn" {
  description = "ARN of the monthly AWS cost budget."
  value       = aws_budgets_budget.monthly_account_cost.arn
}

output "monthly_budget_limit_usd" {
  description = "Configured monthly cost budget limit in USD."
  value       = var.monthly_budget_limit_usd
}
