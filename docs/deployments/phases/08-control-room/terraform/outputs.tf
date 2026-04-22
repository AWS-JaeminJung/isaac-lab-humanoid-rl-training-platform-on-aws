################################################################################
# Phase 08 - Control Room: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# Namespace
# ===========================================================================

output "monitoring_namespace" {
  description = "Kubernetes namespace where the monitoring stack is deployed."
  value       = kubernetes_namespace.monitoring.metadata[0].name
}

# ===========================================================================
# Secrets Manager ARNs
# ===========================================================================

output "grafana_admin_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Grafana admin credentials."
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "grafana_oidc_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Grafana OIDC client secret."
  value       = aws_secretsmanager_secret.grafana_oidc.arn
}

# ===========================================================================
# Connection Info (consumed by install scripts)
# ===========================================================================

output "grafana_hostname" {
  description = "FQDN for the Grafana Ingress."
  value       = "grafana.${var.domain}"
}

# ===========================================================================
# Pass-through outputs (convenience for downstream phases)
# ===========================================================================

output "acm_certificate_arn" {
  description = "ACM certificate ARN (passed through from Phase 01 for convenience)."
  value       = local.acm_certificate_arn
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID (passed through from Phase 01 for convenience)."
  value       = local.hosted_zone_id
}

output "cluster_name" {
  description = "EKS cluster name (passed through from Phase 02 for convenience)."
  value       = local.cluster_name
}
