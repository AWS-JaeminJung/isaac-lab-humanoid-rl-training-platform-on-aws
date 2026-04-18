################################################################################
# Phase 09 - Lobby: Main Resources
#
# Creates the JupyterHub namespace, AWS Secrets Manager secret for the
# OIDC client credentials, and an ExternalSecret resource to sync it
# into the Kubernetes cluster.
################################################################################

# ===========================================================================
# JupyterHub Namespace
# ===========================================================================

resource "kubernetes_namespace" "jupyterhub" {
  metadata {
    name = "jupyterhub"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "lobby"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# Secrets Manager - JupyterHub OIDC Client Secret
# ===========================================================================

resource "aws_secretsmanager_secret" "jupyterhub_oidc" {
  name        = "${var.s3_prefix}/jupyterhub-oidc"
  description = "OIDC client secret for JupyterHub Keycloak integration."

  tags = {
    Component = "jupyterhub"
    Phase     = "09-lobby"
  }
}

resource "aws_secretsmanager_secret_version" "jupyterhub_oidc" {
  secret_id = aws_secretsmanager_secret.jupyterhub_oidc.id

  # Placeholder values - populated from Keycloak Phase 04 client secret
  secret_string = jsonencode({
    client_id     = "jupyterhub"
    client_secret = "POPULATED_BY_KEYCLOAK_PHASE04"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# ExternalSecret - JupyterHub OIDC Client Secret
# ===========================================================================

module "external_secret_jupyterhub_oidc" {
  source = "../../../modules/external-secret"

  secret_name         = "jupyterhub-oidc-credentials"
  namespace           = kubernetes_namespace.jupyterhub.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.jupyterhub_oidc.name
  refresh_interval    = "1h"

  data_map = {
    "client-id"     = "client_id"
    "client-secret" = "client_secret"
  }
}
