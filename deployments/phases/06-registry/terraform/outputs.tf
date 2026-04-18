################################################################################
# Phase 06 - Registry: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# Namespace
# ===========================================================================

output "mlflow_namespace" {
  description = "Kubernetes namespace where MLflow is deployed."
  value       = kubernetes_namespace.mlflow.metadata[0].name
}

# ===========================================================================
# Secrets Manager ARNs
# ===========================================================================

output "mlflow_db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing MLflow DB credentials."
  value       = aws_secretsmanager_secret.mlflow_db.arn
}

output "mlflow_oauth2_proxy_secret_arn" {
  description = "ARN of the Secrets Manager secret containing MLflow OAuth2 Proxy credentials."
  value       = aws_secretsmanager_secret.mlflow_oauth2_proxy.arn
}

# ===========================================================================
# Connection Info (consumed by install scripts)
# ===========================================================================

output "mlflow_hostname" {
  description = "FQDN for the MLflow Ingress."
  value       = "mlflow.${var.domain}"
}

# ===========================================================================
# Pass-through outputs (convenience for downstream phases)
# ===========================================================================

output "s3_models_bucket" {
  description = "Name of the S3 bucket for MLflow model artifacts (passed through from Phase 02)."
  value       = local.s3_models_bucket
}

output "rds_endpoint" {
  description = "RDS endpoint (passed through from Phase 02 for convenience)."
  value       = local.rds_endpoint
}

output "rds_port" {
  description = "RDS port (passed through from Phase 02 for convenience)."
  value       = local.rds_port
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN (passed through from Phase 01 for convenience)."
  value       = local.acm_certificate_arn
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID (passed through from Phase 01 for convenience)."
  value       = local.hosted_zone_id
}

output "irsa_mlflow_role_arn" {
  description = "ARN of the IAM role for the MLflow service account (passed through from Phase 02)."
  value       = local.irsa_mlflow_role_arn
}
