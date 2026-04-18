################################################################################
# Phase 07 - Recorder: Data Sources
#
# Retrieves outputs from Phase 01 (Foundation) and Phase 02 (Platform) via
# remote state, plus account identity information.
################################################################################

# ---------------------------------------------------------------------------
# Phase 01 remote state - VPC, DNS, certificates, security groups
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
# Phase 02 remote state - EKS cluster, RDS, S3, IRSA roles
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
# AWS identity
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Convenience locals for upstream outputs
# ---------------------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Phase 02 - Platform
  cluster_name            = data.terraform_remote_state.platform.outputs.cluster_name
  irsa_fluent_bit_role_arn = data.terraform_remote_state.platform.outputs.irsa_fluent_bit_role_arn
}
