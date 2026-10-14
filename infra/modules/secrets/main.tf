locals {
  secrets = {
    deepseek_api_key = {
      name        = "${var.name_prefix}-deepseek-api-key"
      description = "DeepSeek API key used by the OpenClaw Agent."
    }

    openclaw_gateway_token = {
      name        = "${var.name_prefix}-gateway-token"
      description = "Gateway authentication token used by OpenClaw."
    }

    quick_api_key = {
      name        = "${var.name_prefix}-quick-api-key"
      description = "Dedicated API key used by Amazon Quick to call the protected API Gateway endpoint."
    }

    qqbot_app_id = {
      name        = "${var.name_prefix}-qqbot-app-id"
      description = "QQBot application ID reserved for future integration."
    }

    qqbot_client_secret = {
      name        = "${var.name_prefix}-qqbot-client-secret"
      description = "QQBot client secret reserved for future integration."
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  name                    = each.value.name
  description             = each.value.description
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days

  tags = {
    Name = each.value.name
  }
}
