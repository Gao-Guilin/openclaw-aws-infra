resource "aws_budgets_budget" "monthly_account_cost" {
  name         = "${var.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = false
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.forecasted_warning_threshold
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [var.sns_topic_arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.actual_warning_threshold
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [var.sns_topic_arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.actual_limit_threshold
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [var.sns_topic_arn]
  }

  tags = {
    Name    = "${var.name_prefix}-monthly-cost"
    Purpose = "cost-control"
    Scope   = "account-wide"
  }
}
