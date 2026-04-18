################################################################################
# Phase 05 - Orchestrator: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# Namespaces
# ===========================================================================

output "orchestration_namespace" {
  description = "Kubernetes namespace where OSMO Controller is deployed."
  value       = kubernetes_namespace.orchestration.metadata[0].name
}

output "ray_system_namespace" {
  description = "Kubernetes namespace where KubeRay Operator is deployed."
  value       = kubernetes_namespace.ray_system.metadata[0].name
}

output "training_namespace" {
  description = "Kubernetes namespace where Ray training workloads run."
  value       = kubernetes_namespace.training.metadata[0].name
}

# ===========================================================================
# Secrets Manager ARNs
# ===========================================================================

output "osmo_db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing OSMO DB credentials."
  value       = aws_secretsmanager_secret.osmo_db.arn
}

output "osmo_oidc_secret_arn" {
  description = "ARN of the Secrets Manager secret containing OSMO OIDC credentials."
  value       = aws_secretsmanager_secret.osmo_oidc.arn
}

# ===========================================================================
# IRSA
# ===========================================================================

output "osmo_irsa_role_arn" {
  description = "ARN of the IAM role for OSMO Controller service account (IRSA)."
  value       = module.osmo_irsa.role_arn
}

# ===========================================================================
# Hostnames (consumed by install scripts and downstream phases)
# ===========================================================================

output "osmo_hostname" {
  description = "FQDN for the OSMO API Ingress."
  value       = "osmo.${var.domain}"
}

output "ray_dashboard_hostname" {
  description = "FQDN for the Ray Dashboard Ingress."
  value       = "ray.${var.domain}"
}

# ===========================================================================
# Pass-through outputs (convenience for downstream phases and scripts)
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

output "ecr_repository_url" {
  description = "ECR repository URL (passed through from Phase 02 for convenience)."
  value       = local.ecr_repository_url
}
