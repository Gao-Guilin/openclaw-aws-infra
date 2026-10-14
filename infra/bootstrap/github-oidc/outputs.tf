output "provider_arn" {
  description = "Account-level GitHub Actions OIDC provider ARN shared by dev and prod."
  value       = aws_iam_openid_connect_provider.github.arn
}
