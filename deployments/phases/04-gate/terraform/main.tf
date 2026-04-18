################################################################################
# Phase 04 - Gate: Main Resources
#
# Creates the Keycloak namespace, AWS Secrets Manager secrets for database
# and LDAP credentials, and ExternalSecret resources to sync them into the
# Kubernetes cluster.
################################################################################

# ===========================================================================
# Keycloak Namespace
# ===========================================================================

resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = "keycloak"

    labels = {
      "app.kubernetes.io/part-of"   = "isaac-lab"
      "app.kubernetes.io/component" = "authentication"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# Secrets Manager - Keycloak DB Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "keycloak_db" {
  name        = "${var.s3_prefix}/keycloak-db-credentials"
  description = "PostgreSQL credentials for the Keycloak database on the shared RDS instance."

  tags = {
    Component = "keycloak"
    Phase     = "04-gate"
  }
}

resource "aws_secretsmanager_secret_version" "keycloak_db" {
  secret_id = aws_secretsmanager_secret.keycloak_db.id

  # Placeholder values - must be updated manually or via CI before first deploy
  secret_string = jsonencode({
    username = "keycloak"
    password = "CHANGE_ME_BEFORE_DEPLOY"
    host     = local.rds_endpoint
    port     = tostring(local.rds_port)
    database = var.keycloak_db_name
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# Secrets Manager - LDAP Bind Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "keycloak_ldap" {
  name        = "${var.s3_prefix}/keycloak-ldap-credentials"
  description = "LDAP bind credentials for Keycloak AD Federation."

  tags = {
    Component = "keycloak"
    Phase     = "04-gate"
  }
}

resource "aws_secretsmanager_secret_version" "keycloak_ldap" {
  secret_id = aws_secretsmanager_secret.keycloak_ldap.id

  # Placeholder values - must be updated manually or via CI before first deploy
  secret_string = jsonencode({
    bind_dn       = var.ldap_bind_dn
    bind_password = "CHANGE_ME_BEFORE_DEPLOY"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# Secrets Manager - OIDC Client Secrets (one per client)
# ===========================================================================

locals {
  oidc_clients = ["jupyterhub", "grafana", "mlflow", "ray-dashboard", "osmo-api"]
}

resource "aws_secretsmanager_secret" "oidc_client" {
  for_each = toset(local.oidc_clients)

  name        = "${var.s3_prefix}/keycloak-oidc-${each.key}"
  description = "OIDC client secret for ${each.key} Keycloak client."

  tags = {
    Component  = "keycloak"
    OIDCClient = each.key
    Phase      = "04-gate"
  }
}

resource "aws_secretsmanager_secret_version" "oidc_client" {
  for_each = toset(local.oidc_clients)

  secret_id = aws_secretsmanager_secret.oidc_client[each.key].id

  # Placeholder - populated by configure-realm.sh after client creation
  secret_string = jsonencode({
    client_id     = each.key
    client_secret = "POPULATED_BY_CONFIGURE_REALM"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# ExternalSecret - Keycloak DB Credentials
# ===========================================================================

module "external_secret_db" {
  source = "../../../modules/external-secret"

  secret_name        = "keycloak-db-credentials"
  namespace          = kubernetes_namespace.keycloak.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.keycloak_db.name
  refresh_interval   = "1h"

  data_map = {
    "username" = "username"
    "password" = "password"
    "host"     = "host"
    "port"     = "port"
    "database" = "database"
  }
}

# ===========================================================================
# ExternalSecret - LDAP Bind Credentials
# ===========================================================================

module "external_secret_ldap" {
  source = "../../../modules/external-secret"

  secret_name        = "keycloak-ldap-credentials"
  namespace          = kubernetes_namespace.keycloak.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.keycloak_ldap.name
  refresh_interval   = "1h"

  data_map = {
    "bind-dn"       = "bind_dn"
    "bind-password" = "bind_password"
  }
}

# ===========================================================================
# ExternalSecret - OIDC Client Secrets (per client)
# ===========================================================================

module "external_secret_oidc" {
  source   = "../../../modules/external-secret"
  for_each = toset(local.oidc_clients)

  secret_name        = "keycloak-oidc-${each.key}"
  namespace          = kubernetes_namespace.keycloak.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.oidc_client[each.key].name
  refresh_interval   = "1h"

  data_map = {
    "client-id"     = "client_id"
    "client-secret" = "client_secret"
  }
}
