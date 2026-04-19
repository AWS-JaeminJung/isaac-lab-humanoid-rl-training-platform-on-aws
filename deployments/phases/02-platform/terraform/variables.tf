################################################################################
# Phase 02 - Platform: Input Variables
################################################################################

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment identifier (e.g. prod, staging, dev)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "environment must be one of: prod, staging, dev."
  }
}

variable "s3_prefix" {
  description = "S3 bucket name prefix for project resources."
  type        = string
  default     = "isaac-lab-prod"
}

variable "tags" {
  description = "Default tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "isaac-lab"
    ManagedBy = "terraform"
    Phase     = "02-platform"
  }
}

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "isaac-lab-production"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.31"

  validation {
    condition     = can(regex("^1\\.(2[89]|3[0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be a supported EKS version (e.g. 1.28, 1.29, 1.30, 1.31)."
  }
}

# ---------------------------------------------------------------------------
# Management Node Group
# ---------------------------------------------------------------------------

variable "management_instance_types" {
  description = "List of EC2 instance types for the management node group."
  type        = list(string)
  default     = ["m6i.2xlarge", "m6i.4xlarge"]
}

variable "management_min_size" {
  description = "Minimum number of nodes in the management node group."
  type        = number
  default     = 3
}

variable "management_max_size" {
  description = "Maximum number of nodes in the management node group."
  type        = number
  default     = 5
}

variable "management_desired_size" {
  description = "Desired number of nodes in the management node group."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL
# ---------------------------------------------------------------------------

variable "rds_instance_class" {
  description = "RDS instance class for the PostgreSQL database."
  type        = string
  default     = "db.r6g.large"
}

variable "rds_storage_size" {
  description = "Allocated storage in GiB for the RDS instance."
  type        = number
  default     = 50
}

# ---------------------------------------------------------------------------
# FSx for Lustre
# ---------------------------------------------------------------------------

variable "fsx_storage_capacity" {
  description = "Storage capacity in GiB for the FSx for Lustre filesystem. Must be a multiple of 1200."
  type        = number
  default     = 1200

  validation {
    condition     = var.fsx_storage_capacity >= 1200 && var.fsx_storage_capacity % 1200 == 0
    error_message = "fsx_storage_capacity must be >= 1200 and a multiple of 1200 for PERSISTENT_2."
  }
}

variable "fsx_throughput" {
  description = "Per-unit storage throughput in MB/s/TiB for FSx for Lustre."
  type        = number
  default     = 250

  validation {
    condition     = contains([125, 250, 500, 1000], var.fsx_throughput)
    error_message = "fsx_throughput must be one of: 125, 250, 500, 1000."
  }
}

# ---------------------------------------------------------------------------
# GPU / Karpenter
# ---------------------------------------------------------------------------

variable "gpu_instance_types" {
  description = "List of GPU instance types for Karpenter-managed nodes."
  type        = list(string)
  default     = ["g7e.48xlarge"]
}

variable "gpu_max_nodes" {
  description = "Maximum number of GPU nodes Karpenter can provision."
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Karpenter version
# ---------------------------------------------------------------------------

variable "karpenter_version" {
  description = "Karpenter version for the Helm chart and CRDs."
  type        = string
  default     = "1.1.0"
}
