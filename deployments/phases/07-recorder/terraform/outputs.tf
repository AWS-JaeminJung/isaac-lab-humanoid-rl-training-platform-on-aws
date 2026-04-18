################################################################################
# Phase 07 - Recorder: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# Namespace
# ===========================================================================

output "logging_namespace" {
  description = "Kubernetes namespace where ClickHouse and Fluent Bit are deployed."
  value       = kubernetes_namespace.logging.metadata[0].name
}

# ===========================================================================
# AWS Backup
# ===========================================================================

output "backup_vault_name" {
  description = "Name of the AWS Backup vault for ClickHouse EBS snapshots."
  value       = aws_backup_vault.clickhouse.name
}

output "backup_plan_id" {
  description = "ID of the AWS Backup plan for daily ClickHouse EBS snapshots."
  value       = aws_backup_plan.clickhouse.id
}

# ===========================================================================
# Connection Info (consumed by install scripts)
# ===========================================================================

output "clickhouse_hostname" {
  description = "FQDN for ClickHouse within the cluster."
  value       = "clickhouse.logging.svc.cluster.local"
}

# ===========================================================================
# Pass-through outputs (convenience for downstream phases)
# ===========================================================================

output "cluster_name" {
  description = "EKS cluster name (passed through from Phase 02 for convenience)."
  value       = local.cluster_name
}
