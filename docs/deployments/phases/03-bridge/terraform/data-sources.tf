################################################################################
# Phase 03 - Bridge: Data Sources
#
# Retrieves outputs from Phase 01 (Foundation) and Phase 02 (Platform) via
# remote state, plus account identity and partition information.
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
# Phase 02 remote state - EKS cluster, storage, IRSA roles, etc.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "isaac-lab-prod-terraform-state"
    key    = "phases/platform/terraform.tfstate"
    region = var.aws_region
  }
}

# ---------------------------------------------------------------------------
# AWS identity and partition
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Convenience locals for Phase 01 and Phase 02 outputs
# ---------------------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Phase 01 - Foundation
  vpc_id = data.terraform_remote_state.foundation.outputs.vpc_id

  # Phase 02 - Platform
  cluster_name          = data.terraform_remote_state.platform.outputs.cluster_name
  cluster_endpoint      = data.terraform_remote_state.platform.outputs.cluster_endpoint
  s3_checkpoints_bucket = data.terraform_remote_state.platform.outputs.s3_checkpoints_bucket
  s3_training_data_bucket = data.terraform_remote_state.platform.outputs.s3_training_data_bucket
  ecr_repository_url    = data.terraform_remote_state.platform.outputs.ecr_repository_url
}
