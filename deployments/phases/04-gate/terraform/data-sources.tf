################################################################################
# Phase 04 - Gate: Data Sources
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
# Phase 02 remote state - EKS cluster, RDS, OIDC provider
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

  # Phase 01 - Foundation
  vpc_id              = data.terraform_remote_state.foundation.outputs.vpc_id
  hosted_zone_id      = data.terraform_remote_state.foundation.outputs.hosted_zone_id
  acm_certificate_arn = data.terraform_remote_state.foundation.outputs.acm_certificate_arn
  sg_alb_id           = data.terraform_remote_state.foundation.outputs.sg_alb_id
  management_subnet_id = data.terraform_remote_state.foundation.outputs.management_subnet_id

  # Phase 02 - Platform
  cluster_name      = data.terraform_remote_state.platform.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.platform.outputs.cluster_endpoint
  rds_endpoint      = data.terraform_remote_state.platform.outputs.rds_endpoint
  rds_port          = data.terraform_remote_state.platform.outputs.rds_port
  oidc_provider_arn = data.terraform_remote_state.platform.outputs.oidc_provider_arn
}
