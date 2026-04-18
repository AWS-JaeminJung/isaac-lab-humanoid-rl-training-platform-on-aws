################################################################################
# Phase 01 - Foundation: Input Variables
################################################################################

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "aws_az" {
  description = "Single availability zone for all subnets (GPU locality)."
  type        = string
  default     = "us-east-1a"
}

variable "vpc_cidr" {
  description = "CIDR block for the Isaac Lab VPC."
  type        = string
  default     = "10.100.0.0/21"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "onprem_cidr" {
  description = "CIDR block for the on-premises network reachable via Direct Connect."
  type        = string
  default     = "10.200.0.0/21"

  validation {
    condition     = can(cidrhost(var.onprem_cidr, 0))
    error_message = "onprem_cidr must be a valid CIDR block."
  }
}

variable "domain" {
  description = "Internal DNS domain for the private hosted zone (e.g. isaac-lab.internal)."
  type        = string
  default     = "isaac-lab.internal"
}

variable "s3_prefix" {
  description = "S3 bucket name prefix for project resources."
  type        = string
  default     = "isaac-lab-prod"
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

variable "subnet_cidrs" {
  description = "Map of subnet names to their CIDR blocks."
  type        = map(string)
  default = {
    gpu_compute    = "10.100.0.0/24"
    management     = "10.100.1.0/24"
    infrastructure = "10.100.2.0/24"
    reserved       = "10.100.3.0/24"
  }

  validation {
    condition = alltrue([
      for k, v in var.subnet_cidrs : can(cidrhost(v, 0))
    ])
    error_message = "All subnet_cidrs values must be valid CIDR blocks."
  }
}

variable "dx_gateway_id" {
  description = "ID of the existing Direct Connect Gateway to associate with the VGW."
  type        = string
}

variable "tags" {
  description = "Default tags applied to all resources."
  type        = map(string)
  default = {
    Project     = "isaac-lab"
    ManagedBy   = "terraform"
    Phase       = "01-foundation"
  }
}
