################################################################################
# Phase 08 - Control Room: Main Resources
#
# Creates the monitoring namespace, AWS Secrets Manager secrets for Grafana
# admin and OIDC credentials, and ExternalSecret resources to sync them
# into the Kubernetes cluster.
################################################################################

# ===========================================================================
# Monitoring Namespace
# ===========================================================================

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "control-room"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# Secrets Manager - Grafana Admin Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "grafana_admin" {
  name        = "${var.s3_prefix}/grafana-admin"
  description = "Admin credentials for the Grafana instance deployed in the monitoring namespace."

  tags = {
    Component = "grafana"
    Phase     = "08-control-room"
  }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id

  # Placeholder values - must be updated manually or via CI before first deploy
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = "CHANGE_ME_BEFORE_DEPLOY"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# Secrets Manager - Grafana OIDC Client Secret
# ===========================================================================

resource "aws_secretsmanager_secret" "grafana_oidc" {
  name        = "${var.s3_prefix}/grafana-oidc"
  description = "OIDC client secret for Grafana Keycloak integration."

  tags = {
    Component = "grafana"
    Phase     = "08-control-room"
  }
}

resource "aws_secretsmanager_secret_version" "grafana_oidc" {
  secret_id = aws_secretsmanager_secret.grafana_oidc.id

  # Placeholder values - populated from Keycloak Phase 04 client secret
  secret_string = jsonencode({
    client_id     = "grafana"
    client_secret = "POPULATED_BY_KEYCLOAK_PHASE04"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# ExternalSecret - Grafana Admin Credentials
# ===========================================================================

module "external_secret_grafana_admin" {
  source = "../../../modules/external-secret"

  secret_name         = "grafana-admin-credentials"
  namespace           = kubernetes_namespace.monitoring.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.grafana_admin.name
  refresh_interval    = "1h"

  data_map = {
    "admin-user"     = "admin-user"
    "admin-password" = "admin-password"
  }
}

# ===========================================================================
# ExternalSecret - Grafana OIDC Client Secret
# ===========================================================================

module "external_secret_grafana_oidc" {
  source = "../../../modules/external-secret"

  secret_name         = "grafana-oidc-credentials"
  namespace           = kubernetes_namespace.monitoring.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.grafana_oidc.name
  refresh_interval    = "1h"

  data_map = {
    "client-id"     = "client_id"
    "client-secret" = "client_secret"
  }
}
