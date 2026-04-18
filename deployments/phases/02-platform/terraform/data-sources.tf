################################################################################
# Phase 02 - Platform: Data Sources
#
# Retrieves outputs from Phase 01 (Foundation) via remote state, plus
# account identity and partition information.
################################################################################

# ---------------------------------------------------------------------------
# Phase 01 remote state - VPC, subnets, security groups, etc.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = "isaac-lab-prod-terraform-state"
    key    = "phases/foundation/terraform.tfstate"
    region = var.aws_region
  }
}

# ---------------------------------------------------------------------------
# AWS identity and partition
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Convenience locals for Phase 01 outputs
# ---------------------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # VPC
  vpc_id = data.terraform_remote_state.foundation.outputs.vpc_id

  # Subnets
  gpu_subnet_id            = data.terraform_remote_state.foundation.outputs.subnet_ids["gpu_compute"]
  management_subnet_id     = data.terraform_remote_state.foundation.outputs.subnet_ids["management"]
  infrastructure_subnet_id = data.terraform_remote_state.foundation.outputs.subnet_ids["infrastructure"]

  # All subnets used by EKS (control plane ENIs span multiple subnets)
  eks_subnet_ids = [
    local.gpu_subnet_id,
    local.management_subnet_id,
    local.infrastructure_subnet_id,
  ]

  # Security groups
  sg_mgmt_node_id    = data.terraform_remote_state.foundation.outputs.security_group_ids["mgmt_node"]
  sg_gpu_node_id     = data.terraform_remote_state.foundation.outputs.security_group_ids["gpu_node"]
  sg_storage_id      = data.terraform_remote_state.foundation.outputs.security_group_ids["storage"]
  sg_vpc_endpoint_id = data.terraform_remote_state.foundation.outputs.security_group_ids["vpc_endpoint"]

  # Availability zone (single AZ design)
  availability_zone = data.terraform_remote_state.foundation.outputs.availability_zone
}
