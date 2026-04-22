################################################################################
# Phase 02 - Platform: IRSA (IAM Roles for Service Accounts)
#
# Creates IAM roles with OIDC trust policies for each Kubernetes service
# account that needs AWS API access. Uses the shared IRSA module.
################################################################################

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ===========================================================================
# 1. EBS CSI Controller
# ===========================================================================

module "irsa_ebs_csi" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-ebs-csi-controller"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "kube-system"
  service_account_name = "ebs-csi-controller-sa"

  policy_arns = [
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]

  tags = var.tags
}

# ===========================================================================
# 2. FSx CSI Controller
# ===========================================================================

module "irsa_fsx_csi" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-fsx-csi-controller"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "kube-system"
  service_account_name = "fsx-csi-controller-sa"

  policy_arns = [
    "arn:${local.partition}:iam::aws:policy/AmazonFSxFullAccess",
  ]

  tags = var.tags
}

# ===========================================================================
# 3. Karpenter Controller
# ===========================================================================

module "irsa_karpenter" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-karpenter"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "karpenter"
  service_account_name = "karpenter"

  policy_arns = [
    aws_iam_policy.karpenter_controller.arn,
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Karpenter Controller IAM Policy
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "Policy for Karpenter controller to manage EC2 instances"
  policy      = data.aws_iam_policy_document.karpenter_controller.json

  tags = {
    Name = "${var.cluster_name}-karpenter-controller"
  }
}

data "aws_iam_policy_document" "karpenter_controller" {
  # EC2 instance management
  statement {
    sid    = "AllowEC2Operations"
    effect = "Allow"
    actions = [
      "ec2:CreateLaunchTemplate",
      "ec2:CreateFleet",
      "ec2:CreateTags",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeSpotPriceHistory",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = ["*"]
  }

  # Pass role to EC2 instances
  statement {
    sid     = "AllowPassRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.karpenter_node.arn,
    ]
  }

  # SSM for AMI resolution
  statement {
    sid    = "AllowSSMGetParameter"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      "arn:${local.partition}:ssm:${var.aws_region}::parameter/aws/service/eks/*",
    ]
  }

  # EKS for cluster info
  statement {
    sid    = "AllowEKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [
      aws_eks_cluster.this.arn,
    ]
  }

  # SQS for interruption handling
  statement {
    sid    = "AllowSQSInterruption"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [
      aws_sqs_queue.karpenter_interruption.arn,
    ]
  }

  # IAM for instance profile management
  statement {
    sid    = "AllowInstanceProfileOps"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["*"]
  }

  # Pricing information for cost-aware scheduling
  statement {
    sid    = "AllowPricingRead"
    effect = "Allow"
    actions = [
      "pricing:GetProducts",
    ]
    resources = ["*"]
  }
}

# ===========================================================================
# 4. AWS Load Balancer Controller
# ===========================================================================

module "irsa_alb_controller" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-alb-controller"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "kube-system"
  service_account_name = "aws-load-balancer-controller"

  policy_arns = [
    aws_iam_policy.alb_controller.arn,
  ]

  tags = var.tags
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller"
  description = "Policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowALBController"
        Effect = "Allow"
        Action = [
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteTags",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVpcs",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:RevokeSecurityGroupIngress",
          "elasticloadbalancing:*",
          "iam:CreateServiceLinkedRole",
          "cognito-idp:DescribeUserPoolClient",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "tag:GetResources",
          "tag:TagResources",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Name = "${var.cluster_name}-alb-controller"
  }
}

# ===========================================================================
# 5. MLflow (S3 models read/write)
# ===========================================================================

module "irsa_mlflow" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-mlflow"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "mlflow"
  service_account_name = "mlflow"

  policy_arns = [
    aws_iam_policy.mlflow_s3.arn,
  ]

  tags = var.tags
}

resource "aws_iam_policy" "mlflow_s3" {
  name        = "${var.cluster_name}-mlflow-s3"
  description = "S3 read/write access for MLflow model artifacts"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMLflowS3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          module.s3_models.bucket_arn,
          "${module.s3_models.bucket_arn}/*",
        ]
      },
    ]
  })

  tags = {
    Name = "${var.cluster_name}-mlflow-s3"
  }
}

# ===========================================================================
# 6. Fluent Bit (S3 logs-archive write)
# ===========================================================================

module "irsa_fluent_bit" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-fluent-bit"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "logging"
  service_account_name = "fluent-bit"

  policy_arns = [
    aws_iam_policy.fluent_bit_s3.arn,
  ]

  tags = var.tags
}

resource "aws_iam_policy" "fluent_bit_s3" {
  name        = "${var.cluster_name}-fluent-bit-s3"
  description = "S3 write access for Fluent Bit log archival"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFluentBitS3Write"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket",
        ]
        Resource = [
          module.s3_logs_archive.bucket_arn,
          "${module.s3_logs_archive.bucket_arn}/*",
        ]
      },
    ]
  })

  tags = {
    Name = "${var.cluster_name}-fluent-bit-s3"
  }
}

# ===========================================================================
# 7. External Secrets Operator (Secrets Manager read)
# ===========================================================================

module "irsa_external_secrets" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-external-secrets"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "external-secrets"
  service_account_name = "external-secrets"

  policy_arns = [
    aws_iam_policy.external_secrets.arn,
  ]

  tags = var.tags
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets"
  description = "Secrets Manager read access for External Secrets Operator"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
          "secretsmanager:ListSecrets",
        ]
        Resource = [
          "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.cluster_name}/*",
        ]
      },
    ]
  })

  tags = {
    Name = "${var.cluster_name}-external-secrets"
  }
}

# ===========================================================================
# 8. Training Job (S3 read/write + FSx)
# ===========================================================================

module "irsa_training_job" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-training-job"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = local.oidc_provider_arn
  namespace            = "training"
  service_account_name = "training-job"

  policy_arns = [
    aws_iam_policy.training_job.arn,
  ]

  tags = var.tags
}

resource "aws_iam_policy" "training_job" {
  name        = "${var.cluster_name}-training-job"
  description = "S3 and FSx access for training job pods"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTrainingS3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          module.s3_checkpoints.bucket_arn,
          "${module.s3_checkpoints.bucket_arn}/*",
          module.s3_models.bucket_arn,
          "${module.s3_models.bucket_arn}/*",
          module.s3_training_data.bucket_arn,
          "${module.s3_training_data.bucket_arn}/*",
        ]
      },
      {
        Sid    = "AllowTrainingFSxAccess"
        Effect = "Allow"
        Action = [
          "fsx:DescribeFileSystems",
          "fsx:DescribeDataRepositoryTasks",
          "fsx:CreateDataRepositoryTask",
        ]
        Resource = [
          aws_fsx_lustre_file_system.training.arn,
        ]
      },
    ]
  })

  tags = {
    Name = "${var.cluster_name}-training-job"
  }
}
