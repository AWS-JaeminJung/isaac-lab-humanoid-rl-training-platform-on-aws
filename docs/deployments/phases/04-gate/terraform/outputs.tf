################################################################################
# Phase 04 - Gate: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# Namespace
# ===========================================================================

output "keycloak_namespace" {
  description = "Kubernetes namespace where Keycloak is deployed."
  value       = kubernetes_namespace.keycloak.metadata[0].name
}

# ===========================================================================
# Secrets Manager ARNs
# ===========================================================================

output "keycloak_db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Keycloak DB credentials."
  value       = aws_secretsmanager_secret.keycloak_db.arn
}

output "keycloak_ldap_secret_arn" {
  description = "ARN of the Secrets Manager secret containing LDAP bind credentials."
  value       = aws_secretsmanager_secret.keycloak_ldap.arn
}

output "oidc_client_secret_arns" {
  description = "Map of OIDC client name to Secrets Manager secret ARN."
  value = {
    for client in local.oidc_clients :
    client => aws_secretsmanager_secret.oidc_client[client].arn
  }
}

# ===========================================================================
# Connection Info (consumed by install scripts)
# ===========================================================================

output "keycloak_hostname" {
  description = "FQDN for the Keycloak Ingress."
  value       = "keycloak.${var.domain}"
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
