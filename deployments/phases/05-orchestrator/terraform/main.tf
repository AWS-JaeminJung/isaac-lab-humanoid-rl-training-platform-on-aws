################################################################################
# Phase 05 - Orchestrator: Main Resources
#
# Creates Kubernetes namespaces for OSMO and KubeRay, AWS Secrets Manager
# secrets for DB and OIDC credentials, ExternalSecret resources to sync them
# into the cluster, IRSA role for OSMO Controller S3 access, and
# ResourceQuota for GPU limits in the training namespace.
################################################################################

# ===========================================================================
# Kubernetes Namespaces
# ===========================================================================

resource "kubernetes_namespace" "orchestration" {
  metadata {
    name = "orchestration"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "orchestration"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "ray_system" {
  metadata {
    name = "ray-system"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "ray-operator"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace" "training" {
  metadata {
    name = "training"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "training"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# Secrets Manager - OSMO DB Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "osmo_db" {
  name        = "${var.s3_prefix}/osmo-db-credentials"
  description = "PostgreSQL credentials for the OSMO database on the shared RDS instance."

  tags = {
    Component = "osmo"
    Phase     = "05-orchestrator"
  }
}

resource "aws_secretsmanager_secret_version" "osmo_db" {
  secret_id = aws_secretsmanager_secret.osmo_db.id

  # Placeholder values - must be updated manually or via CI before first deploy
  secret_string = jsonencode({
    username = "osmo"
    password = "CHANGE_ME_BEFORE_DEPLOY"
    host     = local.rds_endpoint
    port     = tostring(local.rds_port)
    database = var.osmo_db_name
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# Secrets Manager - OSMO OIDC Credentials
# ===========================================================================

resource "aws_secretsmanager_secret" "osmo_oidc" {
  name        = "${var.s3_prefix}/osmo-oidc-credentials"
  description = "OIDC client credentials for OSMO API authentication via Keycloak."

  tags = {
    Component = "osmo"
    Phase     = "05-orchestrator"
  }
}

resource "aws_secretsmanager_secret_version" "osmo_oidc" {
  secret_id = aws_secretsmanager_secret.osmo_oidc.id

  # Placeholder values - populated by configure-realm.sh after client creation
  secret_string = jsonencode({
    client_id     = "osmo-api"
    client_secret = "POPULATED_BY_CONFIGURE_REALM"
    issuer_url    = "https://${local.keycloak_hostname}/realms/isaac-lab-production"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ===========================================================================
# ExternalSecret - OSMO DB Credentials
# ===========================================================================

module "external_secret_osmo_db" {
  source = "../../../modules/external-secret"

  secret_name         = "osmo-db-credentials"
  namespace           = kubernetes_namespace.orchestration.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.osmo_db.name
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
# ExternalSecret - OSMO OIDC Credentials
# ===========================================================================

module "external_secret_osmo_oidc" {
  source = "../../../modules/external-secret"

  secret_name         = "osmo-oidc-credentials"
  namespace           = kubernetes_namespace.orchestration.metadata[0].name
  secrets_manager_key = aws_secretsmanager_secret.osmo_oidc.name
  refresh_interval    = "1h"

  data_map = {
    "client-id"     = "client_id"
    "client-secret" = "client_secret"
    "issuer-url"    = "issuer_url"
  }
}

# ===========================================================================
# IAM Policy - OSMO Controller S3 Read/Write
# ===========================================================================

resource "aws_iam_policy" "osmo_s3_access" {
  name        = "osmo-controller-s3-access"
  description = "Allows OSMO Controller to read/write training data and checkpoint S3 buckets."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          "arn:aws:s3:::${local.s3_checkpoints_bucket}",
          "arn:aws:s3:::${local.s3_checkpoints_bucket}/*",
          "arn:aws:s3:::${local.s3_training_data_bucket}",
          "arn:aws:s3:::${local.s3_training_data_bucket}/*",
        ]
      }
    ]
  })

  tags = {
    Component = "osmo"
    Phase     = "05-orchestrator"
  }
}

# ===========================================================================
# IRSA - OSMO Controller Service Account
# ===========================================================================

module "osmo_irsa" {
  source = "../../../modules/irsa"

  role_name            = "osmo-controller-role"
  cluster_name         = local.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = kubernetes_namespace.orchestration.metadata[0].name
  service_account_name = "osmo-controller-sa"
  policy_arns          = [aws_iam_policy.osmo_s3_access.arn]

  tags = {
    Component = "osmo"
    Phase     = "05-orchestrator"
  }
}

# ===========================================================================
# ResourceQuota - Training Namespace GPU Limits
# ===========================================================================

resource "kubernetes_resource_quota" "training_gpu" {
  metadata {
    name      = "training-gpu-quota"
    namespace = kubernetes_namespace.training.metadata[0].name

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "training"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    hard = {
      "requests.nvidia.com/gpu" = tostring(var.training_gpu_limit)
      "limits.nvidia.com/gpu"   = tostring(var.training_gpu_limit)
    }
  }
}
