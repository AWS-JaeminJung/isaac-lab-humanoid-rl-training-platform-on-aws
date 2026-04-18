################################################################################
# Phase 09 - Lobby: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# Namespace
# ===========================================================================

output "jupyterhub_namespace" {
  description = "Kubernetes namespace where JupyterHub is deployed."
  value       = kubernetes_namespace.jupyterhub.metadata[0].name
}

# ===========================================================================
# Secrets Manager ARNs
# ===========================================================================

output "jupyterhub_oidc_secret_arn" {
  description = "ARN of the Secrets Manager secret containing JupyterHub OIDC client secret."
  value       = aws_secretsmanager_secret.jupyterhub_oidc.arn
}

# ===========================================================================
# Connection Info (consumed by install scripts)
# ===========================================================================

output "jupyterhub_hostname" {
  description = "FQDN for the JupyterHub Ingress."
  value       = "jupyter.${var.domain}"
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

output "ecr_repository_url" {
  description = "ECR repository URL (passed through from Phase 02 for convenience)."
  value       = local.ecr_repository_url
}
