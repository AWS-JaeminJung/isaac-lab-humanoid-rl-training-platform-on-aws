################################################################################
# Phase 07 - Recorder: Main Resources
#
# Creates the logging namespace, Fluent Bit ServiceAccount with IRSA
# annotation, and AWS Backup vault/plan for daily EBS snapshots of the
# ClickHouse volume.
################################################################################

# ===========================================================================
# Logging Namespace
# ===========================================================================

resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "recorder"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# ServiceAccount - Fluent Bit (IRSA-annotated for S3/CloudWatch access)
# ===========================================================================

resource "kubernetes_service_account" "fluent_bit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace.logging.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = local.irsa_fluent_bit_role_arn
    }

    labels = {
      "app.kubernetes.io/part-of"    = "isaac-lab"
      "app.kubernetes.io/component"  = "recorder"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ===========================================================================
# AWS Backup - Vault
# ===========================================================================

resource "aws_backup_vault" "clickhouse" {
  name = "${var.s3_prefix}-clickhouse-backup-vault"

  tags = {
    Component = "clickhouse"
    Phase     = "07-recorder"
  }
}

# ===========================================================================
# AWS Backup - IAM Role
# ===========================================================================

data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.s3_prefix}-clickhouse-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json

  tags = {
    Component = "clickhouse"
    Phase     = "07-recorder"
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restores" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ===========================================================================
# AWS Backup - Plan (daily EBS snapshots)
# ===========================================================================

resource "aws_backup_plan" "clickhouse" {
  name = "${var.s3_prefix}-clickhouse-daily"

  rule {
    rule_name         = "daily-ebs-snapshot"
    target_vault_name = aws_backup_vault.clickhouse.name
    schedule          = var.backup_schedule

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }

  tags = {
    Component = "clickhouse"
    Phase     = "07-recorder"
  }
}

# ===========================================================================
# AWS Backup - Selection (tag-based for ClickHouse EBS volumes)
# ===========================================================================

resource "aws_backup_selection" "clickhouse" {
  name         = "${var.s3_prefix}-clickhouse-volumes"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.clickhouse.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "kubernetes.io/created-for/pvc/name"
    value = "data-clickhouse-0"
  }
}
