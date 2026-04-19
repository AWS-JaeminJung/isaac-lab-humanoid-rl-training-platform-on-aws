################################################################################
# Isaac Lab Production Environment Overrides
#
# Production-specific sizing and configuration. These values override
# the base.tfvars defaults for the production deployment.
################################################################################

# ---------------------------------------------------------------------------
# EKS Management Node Group
# ---------------------------------------------------------------------------
# Runs: Karpenter, CoreDNS, CSI drivers, Keycloak, MLflow, JupyterHub,
#       Grafana, Prometheus, ClickHouse, OSMO Controller, Ray Head, Fluent Bit
management_instance_types = ["m6i.2xlarge", "m6i.4xlarge"]
management_min_size       = 3
management_max_size       = 5
management_desired_size   = 3

# ---------------------------------------------------------------------------
# GPU Nodes (Karpenter-managed)
# ---------------------------------------------------------------------------
# g7e.48xlarge: 8x NVIDIA L40S, 192 vCPU, 768 GiB RAM, EFA-enabled
# Scale 0-10 based on training workload demand
gpu_instance_type  = "g7e.48xlarge"
gpu_max_nodes      = 10
gpu_gpus_per_node  = 8

# ---------------------------------------------------------------------------
# RDS PostgreSQL (shared by Keycloak + MLflow)
# ---------------------------------------------------------------------------
rds_instance_class    = "db.r6g.large"
rds_allocated_storage = 50
rds_engine_version    = "15.7"
rds_multi_az          = false
rds_backup_retention  = 7

# ---------------------------------------------------------------------------
# FSx for Lustre (shared high-performance storage)
# ---------------------------------------------------------------------------
# 1200 GiB: minimum for PERSISTENT_2, enough for concurrent checkpoints
# 250 MB/s/TiB throughput: supports multi-node checkpoint I/O
fsx_storage_capacity    = 1200
fsx_deployment_type     = "PERSISTENT_2"
fsx_per_unit_throughput = 250

# ---------------------------------------------------------------------------
# S3 Buckets
# ---------------------------------------------------------------------------
s3_versioning_enabled      = true
s3_lifecycle_glacier_days  = 365

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
prometheus_retention_days  = 15
prometheus_storage_size    = "100Gi"
grafana_admin_password     = ""  # Set via secrets.env or Secrets Manager

# ---------------------------------------------------------------------------
# JupyterHub
# ---------------------------------------------------------------------------
jupyterhub_max_users         = 10
jupyterhub_cpu_per_user      = 2
jupyterhub_memory_per_user   = "4Gi"
jupyterhub_idle_timeout      = 3600

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------
extra_tags = {
  Project     = "isaac-lab"
  Environment = "production"
  Team        = "robotics-research"
  ManagedBy   = "terraform"
}
