#!/usr/bin/env bash
################################################################################
# install-helm-charts.sh
#
# Installs Helm charts for:
#   1. FSx CSI Driver
#   2. Karpenter
#   3. AWS Load Balancer Controller
#   4. External Secrets Operator
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"
# shellcheck source=../../../../lib/helm.sh
source "${SCRIPT_DIR}/../../../lib/helm.sh"

# ---------------------------------------------------------------------------
# Config paths
# ---------------------------------------------------------------------------

KARPENTER_VALUES="${SCRIPT_DIR}/../../../config/helm/karpenter-values.yaml"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

CLUSTER_NAME="$(get_tf_output cluster_name)"
CLUSTER_ENDPOINT="$(get_tf_output cluster_endpoint)"
KARPENTER_ROLE_ARN="$(get_tf_output karpenter_role_arn)"
KARPENTER_QUEUE_NAME="$(get_tf_output karpenter_queue_name)"
ALB_ROLE_ARN="$(get_tf_output irsa_alb_controller_role_arn)"
FSX_CSI_ROLE_ARN="$(get_tf_output irsa_fsx_csi_role_arn)"
ESO_ROLE_ARN="$(get_tf_output irsa_external_secrets_role_arn)"
AWS_REGION="${AWS_REGION:-$(get_tf_output aws_region 2>/dev/null || echo "us-east-1")}"

log_info "Cluster: ${CLUSTER_NAME}"
log_info "Region: ${AWS_REGION}"

# ===========================================================================
# 1. FSx CSI Driver
# ===========================================================================

step_start "FSx CSI Driver"

helm_repo_add "aws-fsx-csi-driver" \
    "https://kubernetes-sigs.github.io/aws-fsx-csi-driver"

helm_install_or_upgrade "aws-fsx-csi-driver" \
    "aws-fsx-csi-driver/aws-fsx-csi-driver" \
    "kube-system" \
    "" \
    --set "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${FSX_CSI_ROLE_ARN}"

step_end

# ===========================================================================
# 2. Karpenter
# ===========================================================================

step_start "Karpenter"

helm_install_or_upgrade "karpenter" \
    "oci://public.ecr.aws/karpenter/karpenter" \
    "karpenter" \
    "${KARPENTER_VALUES}" \
    --version "1.1.0" \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
    --set "settings.interruptionQueue=${KARPENTER_QUEUE_NAME}" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KARPENTER_ROLE_ARN}"

step_end

# ===========================================================================
# 3. AWS Load Balancer Controller
# ===========================================================================

step_start "AWS Load Balancer Controller"

helm_repo_add "eks" \
    "https://aws.github.io/eks-charts"

helm_install_or_upgrade "aws-load-balancer-controller" \
    "eks/aws-load-balancer-controller" \
    "kube-system" \
    "" \
    --set "clusterName=${CLUSTER_NAME}" \
    --set "region=${AWS_REGION}" \
    --set "vpcId=$(terraform -chdir="${TERRAFORM_DIR}" output -raw vpc_id 2>/dev/null || echo "")" \
    --set "serviceAccount.name=aws-load-balancer-controller" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ALB_ROLE_ARN}" \
    --set "nodeSelector.node-type=management"

step_end

# ===========================================================================
# 4. External Secrets Operator
# ===========================================================================

step_start "External Secrets Operator"

helm_repo_add "external-secrets" \
    "https://charts.external-secrets.io"

helm_install_or_upgrade "external-secrets" \
    "external-secrets/external-secrets" \
    "external-secrets" \
    "" \
    --set "installCRDs=true" \
    --set "serviceAccount.name=external-secrets" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ESO_ROLE_ARN}" \
    --set "nodeSelector.node-type=management"

step_end

log_success "All Helm charts installed successfully"
