output "key_id" {
  description = "ID of the OpenClaw-AWS KMS key."
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "ARN of the OpenClaw-AWS KMS key."
  value       = aws_kms_key.this.arn
}

output "alias_name" {
  description = "Alias name of the OpenClaw-AWS KMS key."
  value       = aws_kms_alias.this.name
}
