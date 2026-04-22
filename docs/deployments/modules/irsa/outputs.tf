################################################################################
# IRSA Module - Outputs
################################################################################

output "role_arn" {
  description = "The ARN of the IAM role created for the service account."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "The name of the IAM role created for the service account."
  value       = aws_iam_role.this.name
}
