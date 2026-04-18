################################################################################
# Phase 03 - Bridge: Input Variables
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
    Phase     = "03-bridge"
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

# ---------------------------------------------------------------------------
# On-Prem / Hybrid Nodes
# ---------------------------------------------------------------------------

variable "onprem_cidr" {
  description = "CIDR block of the on-premises network (used for documentation and future SG rules)."
  type        = string
  default     = "10.200.0.0/21"
}

variable "ssm_activation_limit" {
  description = "Maximum number of on-prem instances that can register with this SSM hybrid activation."
  type        = number
  default     = 20

  validation {
    condition     = var.ssm_activation_limit >= 1 && var.ssm_activation_limit <= 1000
    error_message = "ssm_activation_limit must be between 1 and 1000."
  }
}

variable "ssm_activation_expiry_days" {
  description = "Number of days before the SSM hybrid activation expires."
  type        = number
  default     = 30

  validation {
    condition     = var.ssm_activation_expiry_days >= 1 && var.ssm_activation_expiry_days <= 365
    error_message = "ssm_activation_expiry_days must be between 1 and 365."
  }
}
