################################################################################
# Phase 06 - Registry: Main Resources
#
# Creates the MLflow namespace, AWS Secrets Manager secrets for database
# and OAuth2 Proxy credentials, ExternalSecret resources to sync them into
# the Kubernetes cluster, and the MLflow ServiceAccount with IRSA annotation.
################################################################################

# ===========================================================================
# MLflow Namespace
# ===========================================================================

resource "kubernetes_namespace" "mlflow" {
  metadata {
    name = "mlflow"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "registry"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# Secrets Manager - MLflow DB Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "mlflow_db" {
  name        = "${var.s3_prefix}/mlflow-db-credentials"
  description = "PostgreSQL credentials for the MLflow database on the shared RDS instance."

  tags = {
    Component = "mlflow"
    Phase     = "06-registry"
  }
}

resource "aws_secretsmanager_secret_version" "mlflow_db" {
  secret_id = aws_secretsmanager_secret.mlflow_db.id

  # Placeholder values - must be updated manually or via CI before first deploy
  secret_string = jsonencode({
    username = "mlflow"
    password = "CHANGE_ME_BEFORE_DEPLOY"
    host     = local.rds_endpoint
    port     = tostring(local.rds_port)
    database = var.mlflow_db_name
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# Secrets Manager - MLflow OAuth2 Proxy Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "mlflow_oauth2_proxy" {
  name        = "${var.s3_prefix}/mlflow-oauth2-proxy"
  description = "OAuth2 Proxy credentials for MLflow OIDC authentication via Keycloak."

  tags = {
    Component = "mlflow"
    Phase     = "06-registry"
  }
}

resource "aws_secretsmanager_secret_version" "mlflow_oauth2_proxy" {
  secret_id = aws_secretsmanager_secret.mlflow_oauth2_proxy.id

  # Placeholder values - populated by install-oauth2-proxy.sh or CI
  secret_string = jsonencode({
    client_id     = "mlflow"
    client_secret = "POPULATED_BY_KEYCLOAK_PHASE04"
    cookie_secret = "CHANGE_ME_BEFORE_DEPLOY"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# ExternalSecret - MLflow DB Credentials
# ===========================================================================

module "external_secret_db" {
  source = "../../../modules/external-secret"

  secret_name         = "mlflow-db-credentials"
  namespace           = kubernetes_namespace.mlflow.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.mlflow_db.name
  refresh_interval    = "1h"

  data_map = {
    "username" = "username"
    "password" = "password"
    "host"     = "host"
    "port"     = "port"
    "database" = "database"
  }
}

# ===========================================================================
# ExternalSecret - MLflow OAuth2 Proxy Credentials
# ===========================================================================

module "external_secret_oauth2_proxy" {
  source = "../../../modules/external-secret"

  secret_name         = "mlflow-oauth2-proxy"
  namespace           = kubernetes_namespace.mlflow.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.mlflow_oauth2_proxy.name
  refresh_interval    = "1h"

  data_map = {
    "client-id"     = "client_id"
    "client-secret" = "client_secret"
    "cookie-secret" = "cookie_secret"
  }
}

# ===========================================================================
# ServiceAccount - MLflow (IRSA-annotated for S3 access)
# ===========================================================================

resource "kubernetes_service_account" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace.mlflow.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = local.irsa_mlflow_role_arn
    }

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "registry"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
