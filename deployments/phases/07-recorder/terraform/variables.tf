################################################################################
# Phase 07 - Recorder: Input Variables
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
    Phase     = "07-recorder"
  }
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

variable "backup_schedule" {
  description = "Cron expression for AWS Backup daily snapshot schedule (UTC)."
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "backup_retention_days" {
  description = "Number of days to retain AWS Backup snapshots."
  type        = number
  default     = 30
}
