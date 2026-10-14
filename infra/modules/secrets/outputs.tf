output "secret_arns" {
  description = "Map of Secrets Manager secret ARNs."
  value = {
    for key, secret in aws_secretsmanager_secret.this :
    key => secret.arn
  }
}

output "secret_names" {
  description = "Map of Secrets Manager secret names."
  value = {
    for key, secret in aws_secretsmanager_secret.this :
    key => secret.name
  }
}

output "deepseek_api_key_secret_arn" {
  description = "ARN of the DeepSeek API key secret."
  value       = aws_secretsmanager_secret.this["deepseek_api_key"].arn
}

output "openclaw_gateway_token_secret_arn" {
  description = "ARN of the OpenClaw gateway token secret."
  value       = aws_secretsmanager_secret.this["openclaw_gateway_token"].arn
}

output "quick_api_key_secret_arn" {
  description = "ARN of the API key secret used by Amazon Quick."
  value       = aws_secretsmanager_secret.this["quick_api_key"].arn
}

output "qqbot_app_id_secret_arn" {
  description = "ARN of the QQBot application ID secret."
  value       = aws_secretsmanager_secret.this["qqbot_app_id"].arn
}

output "qqbot_client_secret_arn" {
  description = "ARN of the QQBot client secret."
  value       = aws_secretsmanager_secret.this["qqbot_client_secret"].arn
}
