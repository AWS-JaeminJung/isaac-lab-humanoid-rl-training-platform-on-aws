################################################################################
# Isaac Lab Production - Base Terraform Variables
#
# These values are shared across ALL environments. Environment-specific
# overrides live in config/env/<environment>.tfvars.
#
# Usage: terraform plan -var-file=config/base.tfvars
################################################################################

# AWS Region and Availability Zone
# Single AZ strategy: EFA requires same AZ, FSx Lustre is single-AZ,
# and cross-AZ latency degrades NCCL performance.
aws_region     = "us-east-1"
aws_az         = "us-east-1a"

# Network CIDR blocks
# VPC:     /21 = 2,048 IPs (current usage ~335, 6x headroom)
# On-Prem: /21 = 2,048 IPs (must not overlap with VPC CIDR)
vpc_cidr       = "10.100.0.0/21"
onprem_cidr    = "10.200.0.0/21"

# EKS Cluster
cluster_name   = "isaac-lab-production"

# DNS
# Private hosted zone for internal service discovery
# All services are accessible via *.internal (e.g., keycloak.internal)
domain         = "isaac-lab.internal"

# S3 bucket naming prefix
# Buckets: {prefix}-checkpoints, {prefix}-artifacts, {prefix}-data, {prefix}-logs
s3_prefix      = "isaac-lab-prod"

# Environment tag (used for resource tagging and config selection)
environment    = "prod"
