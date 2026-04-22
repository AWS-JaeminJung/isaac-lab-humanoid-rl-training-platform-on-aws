################################################################################
# Phase 03 - Bridge: SSM Hybrid Activation & IAM for On-Prem GPU Nodes
#
# Creates the IAM role assumed by on-prem machines when they register as
# EKS Hybrid Nodes via SSM, plus the SSM Hybrid Activation itself.
################################################################################

# ---------------------------------------------------------------------------
# IAM Role: HybridNodeRole - assumed by SSM-managed on-prem instances
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "hybrid_node_assume_role" {
  statement {
    sid     = "AllowSSMServiceAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hybrid_node" {
  name               = "${var.cluster_name}-hybrid-node-role"
  assume_role_policy = data.aws_iam_policy_document.hybrid_node_assume_role.json

  tags = {
    Name = "${var.cluster_name}-hybrid-node-role"
  }
}

# ---------------------------------------------------------------------------
# Managed policies for SSM core functionality
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "hybrid_ssm_core" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------------------------------------------------------------------------
# EKS access policy - allows nodes to describe their cluster
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "hybrid_eks" {
  statement {
    sid    = "AllowEKSDescribeCluster"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [
      "arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/${local.cluster_name}",
    ]
  }
}

resource "aws_iam_policy" "hybrid_eks" {
  name        = "${var.cluster_name}-hybrid-eks-access"
  description = "Allows hybrid nodes to describe the EKS cluster for nodeadm bootstrap."
  policy      = data.aws_iam_policy_document.hybrid_eks.json

  tags = {
    Name = "${var.cluster_name}-hybrid-eks-access"
  }
}

resource "aws_iam_role_policy_attachment" "hybrid_eks" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = aws_iam_policy.hybrid_eks.arn
}

# ---------------------------------------------------------------------------
# ECR access policy - allows nodes to pull container images
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "hybrid_ecr" {
  statement {
    sid    = "AllowECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowECRPull"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [
      "arn:${local.partition}:ecr:${var.aws_region}:${local.account_id}:repository/*",
    ]
  }
}

resource "aws_iam_policy" "hybrid_ecr" {
  name        = "${var.cluster_name}-hybrid-ecr-access"
  description = "Allows hybrid nodes to authenticate and pull images from ECR."
  policy      = data.aws_iam_policy_document.hybrid_ecr.json

  tags = {
    Name = "${var.cluster_name}-hybrid-ecr-access"
  }
}

resource "aws_iam_role_policy_attachment" "hybrid_ecr" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = aws_iam_policy.hybrid_ecr.arn
}

# ---------------------------------------------------------------------------
# S3 access policy - allows nodes to read training data and checkpoints
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "hybrid_s3" {
  statement {
    sid    = "AllowS3Read"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:${local.partition}:s3:::${local.s3_checkpoints_bucket}",
      "arn:${local.partition}:s3:::${local.s3_checkpoints_bucket}/*",
      "arn:${local.partition}:s3:::${local.s3_training_data_bucket}",
      "arn:${local.partition}:s3:::${local.s3_training_data_bucket}/*",
    ]
  }
}

resource "aws_iam_policy" "hybrid_s3" {
  name        = "${var.cluster_name}-hybrid-s3-access"
  description = "Allows hybrid nodes to read from checkpoints and training data S3 buckets."
  policy      = data.aws_iam_policy_document.hybrid_s3.json

  tags = {
    Name = "${var.cluster_name}-hybrid-s3-access"
  }
}

resource "aws_iam_role_policy_attachment" "hybrid_s3" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = aws_iam_policy.hybrid_s3.arn
}

# ---------------------------------------------------------------------------
# SSM Hybrid Activation
#
# On-prem machines use the activation ID and code to register with SSM,
# which then allows them to join the EKS cluster as hybrid nodes.
# ---------------------------------------------------------------------------

resource "time_offset" "ssm_expiry" {
  offset_days = var.ssm_activation_expiry_days
}

resource "aws_ssm_activation" "hybrid_nodes" {
  name               = "${var.cluster_name}-hybrid-activation"
  description        = "SSM Hybrid Activation for on-prem GPU nodes joining EKS cluster ${local.cluster_name}"
  iam_role            = aws_iam_role.hybrid_node.id
  registration_limit = var.ssm_activation_limit
  expiration_date    = time_offset.ssm_expiry.rfc3339

  tags = {
    Name = "${var.cluster_name}-hybrid-activation"
  }

  depends_on = [
    aws_iam_role_policy_attachment.hybrid_ssm_core,
    aws_iam_role_policy_attachment.hybrid_eks,
    aws_iam_role_policy_attachment.hybrid_ecr,
    aws_iam_role_policy_attachment.hybrid_s3,
  ]
}

# ---------------------------------------------------------------------------
# EKS Access Entry for Hybrid Nodes
#
# Grants the HybridNodeRole permission to join the EKS cluster via the
# EKS access entry API (available in EKS 1.30+).
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "hybrid_nodes" {
  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.hybrid_node.arn
  type          = "HYBRID_LINUX"

  tags = {
    Name = "${var.cluster_name}-hybrid-access-entry"
  }
}
