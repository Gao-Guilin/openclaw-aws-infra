locals {
  name_prefix     = "${var.project_name}-${var.environment}"
  agent_image_uri = var.agent_image_uri_override != "" ? var.agent_image_uri_override : "${module.ecr.repository_url}@${var.agent_image_digest}"

  common_tags = merge(
    var.additional_tags,
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  )
}
