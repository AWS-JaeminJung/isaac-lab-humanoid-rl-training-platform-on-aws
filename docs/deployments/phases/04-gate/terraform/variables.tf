################################################################################
# Phase 04 - Gate: Input Variables
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
    Phase     = "04-gate"
  }
}

# ---------------------------------------------------------------------------
# Keycloak Database
# ---------------------------------------------------------------------------

variable "keycloak_db_name" {
  description = "Name of the PostgreSQL database for Keycloak on the shared RDS instance."
  type        = string
  default     = "keycloak_db"
}

# ---------------------------------------------------------------------------
# LDAP / Active Directory Federation
# ---------------------------------------------------------------------------

variable "ldap_url" {
  description = "LDAPS connection URL for the on-premises Active Directory server."
  type        = string
  default     = "ldaps://ad.corp.internal:636"
}

variable "ldap_bind_dn" {
  description = "Distinguished Name of the service account used to bind to LDAP."
  type        = string
  default     = "CN=svc-keycloak,OU=ServiceAccounts,DC=corp,DC=internal"
}

variable "ldap_users_dn" {
  description = "Base DN under which LDAP user searches are performed."
  type        = string
  default     = "OU=Users,DC=corp,DC=internal"
}
