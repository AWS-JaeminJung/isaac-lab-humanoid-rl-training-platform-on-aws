################################################################################
# Phase 01 - Foundation: Remote State Backend
#
# S3 backend with DynamoDB state locking. The bucket and lock table must be
# created out-of-band (bootstrap) before running terraform init.
################################################################################

terraform {
  backend "s3" {
    bucket         = "isaac-lab-prod-terraform-state"
    key            = "phases/foundation/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "isaac-lab-prod-terraform-locks"
    encrypt        = true
  }
}
