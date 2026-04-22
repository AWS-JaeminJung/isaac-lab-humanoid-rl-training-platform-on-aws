################################################################################
# Phase 02 - Platform: EKS Cluster & Management Node Group
#
# Creates the EKS cluster with private-only API endpoint and a managed
# node group for system/management workloads.
################################################################################

# ---------------------------------------------------------------------------
# KMS key for EKS secrets envelope encryption
# ---------------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS secrets encryption - ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.cluster_name}-eks-secrets"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# ---------------------------------------------------------------------------
# EKS Cluster IAM Role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    sid     = "AllowEKSServiceAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json

  tags = {
    Name = "${var.cluster_name}-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = false

    subnet_ids         = local.eks_subnet_ids
    security_group_ids = [local.sg_mgmt_node_id]
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # Ensure IAM role is created before the cluster
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]

  tags = {
    Name = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# EKS Control Plane Log Group (30 day retention)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30

  tags = {
    Name = "${var.cluster_name}-control-plane-logs"
  }
}

# ---------------------------------------------------------------------------
# OIDC Identity Provider for IRSA
# ---------------------------------------------------------------------------

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.cluster_name}-oidc"
  }
}

# ---------------------------------------------------------------------------
# Management Node Group IAM Role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    sid     = "AllowEC2ServiceAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "management_node" {
  name               = "${var.cluster_name}-management-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = {
    Name = "${var.cluster_name}-management-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "management_worker" {
  role       = aws_iam_role.management_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "management_cni" {
  role       = aws_iam_role.management_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "management_ecr" {
  role       = aws_iam_role.management_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "management_ssm" {
  role       = aws_iam_role.management_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------------------------------------------------------------------------
# EKS Managed Node Group - Management
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "management" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "management"
  node_role_arn   = aws_iam_role.management_node.arn

  subnet_ids     = [local.management_subnet_id]
  instance_types = var.management_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    min_size     = var.management_min_size
    max_size     = var.management_max_size
    desired_size = var.management_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "node-type" = "management"
  }

  tags = {
    Name                                          = "${var.cluster_name}-management"
    "k8s.io/cluster-autoscaler/enabled"           = "false"
    "karpenter.sh/discovery"                      = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.management_worker,
    aws_iam_role_policy_attachment.management_cni,
    aws_iam_role_policy_attachment.management_ecr,
    aws_iam_role_policy_attachment.management_ssm,
  ]
}

# ---------------------------------------------------------------------------
# GPU Baseline Node Group IAM Role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "gpu_baseline_node" {
  name               = "${var.cluster_name}-gpu-baseline-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = {
    Name = "${var.cluster_name}-gpu-baseline-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "gpu_baseline_worker" {
  role       = aws_iam_role.gpu_baseline_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "gpu_baseline_cni" {
  role       = aws_iam_role.gpu_baseline_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "gpu_baseline_ecr" {
  role       = aws_iam_role.gpu_baseline_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "gpu_baseline_ssm" {
  role       = aws_iam_role.gpu_baseline_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------------------------------------------------------------------------
# EKS Managed Node Group - GPU Baseline (On-Demand, always-on)
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "gpu_baseline" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "gpu-baseline"
  node_role_arn   = aws_iam_role.gpu_baseline_node.arn

  subnet_ids     = [local.gpu_subnet_id]
  instance_types = var.gpu_baseline_instance_types
  ami_type       = "AL2023_x86_64_NVIDIA"
  capacity_type  = "ON_DEMAND"

  scaling_config {
    min_size     = var.gpu_baseline_min_size
    max_size     = var.gpu_baseline_max_size
    desired_size = var.gpu_baseline_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "node-type" = "gpu"
    "gpu-tier"  = "baseline"
  }

  taint {
    key    = "nvidia.com/gpu"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Name                                          = "${var.cluster_name}-gpu-baseline"
    "k8s.io/cluster-autoscaler/enabled"           = "false"
    "karpenter.sh/discovery"                      = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.gpu_baseline_worker,
    aws_iam_role_policy_attachment.gpu_baseline_cni,
    aws_iam_role_policy_attachment.gpu_baseline_ecr,
    aws_iam_role_policy_attachment.gpu_baseline_ssm,
  ]
}
