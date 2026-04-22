################################################################################
# IRSA (IAM Roles for Service Accounts) Module
#
# Creates an IAM Role with an OIDC trust policy that allows a specific
# Kubernetes service account to assume it. This is the standard EKS pattern
# for granting AWS permissions to pods without embedding credentials.
#
# The trust policy uses a StringEquals condition on the OIDC subject claim
# to restrict assumption to the exact namespace/service-account pair.
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Derive the OIDC issuer URL from the provider ARN
# ---------------------------------------------------------------------------

locals {
  # Extract the OIDC issuer host from the provider ARN.
  # ARN format: arn:aws:iam::<account>:oidc-provider/<issuer-host>
  oidc_issuer = replace(var.oidc_provider_arn, "/^(.*provider\\/)/", "")
}

# ---------------------------------------------------------------------------
# Trust policy - allow the EKS OIDC provider to assume this role for the
# specified namespace and service account.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowEKSServiceAccountAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# IAM Role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(
    var.tags,
    {
      "eks.amazonaws.com/cluster"         = var.cluster_name
      "eks.amazonaws.com/namespace"       = var.namespace
      "eks.amazonaws.com/service-account" = var.service_account_name
    },
  )
}

# ---------------------------------------------------------------------------
# Attach managed / customer policies
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(var.policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}
