################################################################################
# Phase 02 - Platform: ECR Repository
#
# Container image repository for Isaac Lab training images.
# Tag immutability prevents overwriting published images.
################################################################################

resource "aws_ecr_repository" "training" {
  name                 = "isaac-lab-training"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "isaac-lab-training"
  }
}

# ---------------------------------------------------------------------------
# Lifecycle policy - keep the 30 most recent images
# ---------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "training" {
  repository = aws_ecr_repository.training.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 30 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}
