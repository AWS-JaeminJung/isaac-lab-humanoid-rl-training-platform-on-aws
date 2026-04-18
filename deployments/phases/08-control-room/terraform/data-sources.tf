################################################################################
# Phase 08 - Control Room: Data Sources
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
# Phase 04 remote state - Keycloak, OIDC client secrets
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
  hosted_zone_id      = data.terraform_remote_state.foundation.outputs.hosted_zone_id
  acm_certificate_arn = data.terraform_remote_state.foundation.outputs.acm_certificate_arn

  # Phase 02 - Platform
  cluster_name = data.terraform_remote_state.platform.outputs.cluster_name

  # Phase 04 - Gate
  keycloak_hostname       = data.terraform_remote_state.gate.outputs.keycloak_hostname
  oidc_client_secret_arns = data.terraform_remote_state.gate.outputs.oidc_client_secret_arns
}
