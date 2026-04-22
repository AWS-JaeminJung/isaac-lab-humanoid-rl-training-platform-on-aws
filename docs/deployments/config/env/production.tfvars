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
# GPU Baseline Node Group (ASG, On-Demand, always-on)
# ---------------------------------------------------------------------------
# g7e.48xlarge: 8x NVIDIA L40S, 192 vCPU, 768 GiB RAM, EFA-enabled
gpu_baseline_instance_types = ["g7e.48xlarge"]
gpu_baseline_min_size       = 2
gpu_baseline_max_size       = 2
gpu_baseline_desired_size   = 2

# ---------------------------------------------------------------------------
# GPU Burst (Karpenter, Spot preferred + On-Demand fallback)
# ---------------------------------------------------------------------------
gpu_burst_spot_instance_types = ["g7e.48xlarge", "g7e.24xlarge", "g7e.12xlarge", "g6e.48xlarge", "g6e.24xlarge", "g6e.12xlarge"]
gpu_burst_od_instance_types   = ["g7e.48xlarge"]
gpu_burst_spot_max_gpus       = 80
gpu_burst_od_max_gpus         = 40

# ---------------------------------------------------------------------------
# RDS PostgreSQL (shared by Keycloak + MLflow)
# ---------------------------------------------------------------------------
rds_instance_class = "db.r6g.large"
rds_storage_size   = 50

# ---------------------------------------------------------------------------
# FSx for Lustre (shared high-performance storage)
# ---------------------------------------------------------------------------
# 1200 GiB: minimum for PERSISTENT_2, enough for concurrent checkpoints
# 250 MB/s/TiB throughput: supports multi-node checkpoint I/O
fsx_storage_capacity = 1200
fsx_throughput       = 250

# ---------------------------------------------------------------------------
# Tags (merged with default tags in variables.tf)
# ---------------------------------------------------------------------------
tags = {
  Project     = "isaac-lab"
  Environment = "production"
  Team        = "robotics-research"
  ManagedBy   = "terraform"
  Phase       = "02-platform"
}
