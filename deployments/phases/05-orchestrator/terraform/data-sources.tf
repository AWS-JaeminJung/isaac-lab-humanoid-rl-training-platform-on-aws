################################################################################
# Phase 05 - Orchestrator: Data Sources
#
# Retrieves outputs from Phase 01 (Foundation), Phase 02 (Platform), and
# Phase 04 (Gate) via remote state, plus account identity information.
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
# Phase 02 remote state - EKS cluster, RDS, ECR, S3, OIDC provider
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
# Phase 04 remote state - Keycloak hostname, OIDC client secret ARNs
# ---------------------------------------------------------------------------

data "terraform_remote_state" "gate" {
  backend = "s3"

  config = {
    bucket = "isaac-lab-prod-terraform-state"
    key    = "phases/gate/terraform.tfstate"
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
  vpc_id               = data.terraform_remote_state.foundation.outputs.vpc_id
  hosted_zone_id       = data.terraform_remote_state.foundation.outputs.hosted_zone_id
  acm_certificate_arn  = data.terraform_remote_state.foundation.outputs.acm_certificate_arn
  sg_alb_id            = data.terraform_remote_state.foundation.outputs.sg_alb_id
  management_subnet_id = data.terraform_remote_state.foundation.outputs.management_subnet_id

  # Phase 02 - Platform
  cluster_name           = data.terraform_remote_state.platform.outputs.cluster_name
  cluster_endpoint       = data.terraform_remote_state.platform.outputs.cluster_endpoint
  oidc_provider_arn      = data.terraform_remote_state.platform.outputs.oidc_provider_arn
  rds_endpoint           = data.terraform_remote_state.platform.outputs.rds_endpoint
  rds_port               = data.terraform_remote_state.platform.outputs.rds_port
  ecr_repository_url     = data.terraform_remote_state.platform.outputs.ecr_repository_url
  s3_checkpoints_bucket  = data.terraform_remote_state.platform.outputs.s3_checkpoints_bucket
  s3_training_data_bucket = data.terraform_remote_state.platform.outputs.s3_training_data_bucket

  # Phase 04 - Gate
  keycloak_hostname       = data.terraform_remote_state.gate.outputs.keycloak_hostname
  oidc_client_secret_arns = data.terraform_remote_state.gate.outputs.oidc_client_secret_arns
}
