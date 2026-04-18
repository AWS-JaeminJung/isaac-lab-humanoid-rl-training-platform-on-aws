#!/usr/bin/env bash
################################################################################
# install-eks-addons.sh
#
# Installs EKS managed add-ons: vpc-cni, coredns, kube-proxy, ebs-csi-driver.
# The EBS CSI driver is configured with IRSA role from terraform output.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

CLUSTER_NAME="$(get_tf_output cluster_name)"
EBS_CSI_ROLE_ARN="$(get_tf_output irsa_ebs_csi_role_arn)"
AWS_REGION="${AWS_REGION:-$(get_tf_output aws_region 2>/dev/null || echo "us-east-1")}"

log_info "Cluster: ${CLUSTER_NAME}"
log_info "Region: ${AWS_REGION}"
log_info "EBS CSI Role ARN: ${EBS_CSI_ROLE_ARN}"

# ---------------------------------------------------------------------------
# Helper: install or update EKS addon
# ---------------------------------------------------------------------------

install_addon() {
    local addon_name="$1"
    local extra_args=("${@:2}")

    log_info "Installing EKS add-on: ${addon_name}"

    # Check if addon already exists
    if aws eks describe-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name "${addon_name}" \
        --region "${AWS_REGION}" &>/dev/null; then
        log_info "Add-on '${addon_name}' already exists, updating..."
        aws eks update-addon \
            --cluster-name "${CLUSTER_NAME}" \
            --addon-name "${addon_name}" \
            --region "${AWS_REGION}" \
            --resolve-conflicts OVERWRITE \
            "${extra_args[@]}" || true
    else
        aws eks create-addon \
            --cluster-name "${CLUSTER_NAME}" \
            --addon-name "${addon_name}" \
            --region "${AWS_REGION}" \
            --resolve-conflicts OVERWRITE \
            "${extra_args[@]}"
    fi

    log_info "Waiting for add-on '${addon_name}' to become ACTIVE..."
    aws eks wait addon-active \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name "${addon_name}" \
        --region "${AWS_REGION}"

    log_success "Add-on '${addon_name}' is ACTIVE"
}

# ---------------------------------------------------------------------------
# Install add-ons
# ---------------------------------------------------------------------------

step_start "VPC CNI"
install_addon "vpc-cni"
step_end

step_start "CoreDNS"
install_addon "coredns"
step_end

step_start "kube-proxy"
install_addon "kube-proxy"
step_end

step_start "EBS CSI Driver"
install_addon "aws-ebs-csi-driver" \
    --service-account-role-arn "${EBS_CSI_ROLE_ARN}"
step_end

log_success "All EKS managed add-ons installed successfully"
