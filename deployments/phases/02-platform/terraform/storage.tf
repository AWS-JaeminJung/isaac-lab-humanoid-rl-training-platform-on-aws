################################################################################
# Phase 02 - Platform: Storage Resources
#
# FSx for Lustre (shared high-performance storage for training),
# S3 buckets (checkpoints, models, logs-archive, training-data).
################################################################################

# ===========================================================================
# FSx for Lustre
# ===========================================================================

resource "aws_fsx_lustre_file_system" "training" {
  deployment_type            = "PERSISTENT_2"
  storage_capacity           = var.fsx_storage_capacity
  per_unit_storage_throughput = var.fsx_throughput
  subnet_ids                 = [local.infrastructure_subnet_id]
  security_group_ids         = [local.sg_storage_id]

  log_configuration {
    level = "WARN_ERROR"
  }

  tags = {
    Name = "${var.cluster_name}-training-fsx"
  }
}

# ===========================================================================
# S3 Buckets (using shared s3-bucket module)
# ===========================================================================

# ---------------------------------------------------------------------------
# Checkpoints: 90 days -> IA, 365 days delete
# ---------------------------------------------------------------------------

module "s3_checkpoints" {
  source = "../../modules/s3-bucket"

  bucket_name = "${var.s3_prefix}-checkpoints"

  lifecycle_rules = [
    {
      id                       = "checkpoints-lifecycle"
      transition_days          = 90
      transition_storage_class = "STANDARD_IA"
      expiration_days          = 365
    },
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Models: permanent storage (no lifecycle rules)
# ---------------------------------------------------------------------------

module "s3_models" {
  source = "../../modules/s3-bucket"

  bucket_name = "${var.s3_prefix}-models"

  lifecycle_rules = []

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Logs Archive: 180 days -> Glacier
# ---------------------------------------------------------------------------

module "s3_logs_archive" {
  source = "../../modules/s3-bucket"

  bucket_name = "${var.s3_prefix}-logs-archive"

  lifecycle_rules = [
    {
      id                       = "logs-archive-lifecycle"
      transition_days          = 180
      transition_storage_class = "GLACIER"
      expiration_days          = null
    },
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Training Data: permanent storage (no lifecycle rules)
# ---------------------------------------------------------------------------

module "s3_training_data" {
  source = "../../modules/s3-bucket"

  bucket_name = "${var.s3_prefix}-training-data"

  lifecycle_rules = []

  tags = var.tags
}
