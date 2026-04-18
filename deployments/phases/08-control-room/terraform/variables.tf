################################################################################
# Phase 08 - Control Room: Input Variables
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

variable "domain" {
  description = "Internal DNS domain for service discovery."
  type        = string
  default     = "isaac-lab.internal"
}

variable "tags" {
  description = "Default tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "isaac-lab"
    ManagedBy = "terraform"
    Phase     = "08-control-room"
  }
}
