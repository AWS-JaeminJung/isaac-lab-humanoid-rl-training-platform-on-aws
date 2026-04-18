#!/usr/bin/env bash
################################################################################
# configure-karpenter.sh
#
# Applies Karpenter NodePool and EC2NodeClass manifests after substituting
# cluster-specific values from terraform output.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
MANIFESTS_DIR="${PHASE_DIR}/manifests"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

CLUSTER_NAME="$(get_tf_output cluster_name)"

log_info "Configuring Karpenter for cluster: ${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Wait for Karpenter to be ready
# ---------------------------------------------------------------------------

step_start "Wait for Karpenter pods"

log_info "Waiting for Karpenter deployment to be ready..."
retry 10 5 kubectl rollout status deployment/karpenter \
    --namespace karpenter \
    --timeout=120s

step_end

# ---------------------------------------------------------------------------
# Apply EC2NodeClass (must be applied before NodePool)
# ---------------------------------------------------------------------------

step_start "Apply EC2NodeClass"

log_info "Substituting CLUSTER_NAME in EC2NodeClass manifest..."
sed "s/CLUSTER_NAME/${CLUSTER_NAME}/g" \
    "${MANIFESTS_DIR}/karpenter-ec2nodeclass.yaml" | \
    kubectl apply -f -

log_success "EC2NodeClass 'gpu-class' applied"
step_end

# ---------------------------------------------------------------------------
# Apply NodePool
# ---------------------------------------------------------------------------

step_start "Apply NodePool"

kubectl apply -f "${MANIFESTS_DIR}/karpenter-nodepool.yaml"

log_success "NodePool 'gpu-pool' applied"
step_end

# ---------------------------------------------------------------------------
# Verify Karpenter resources
# ---------------------------------------------------------------------------

step_start "Verify Karpenter resources"

log_info "Checking NodePool status..."
kubectl get nodepool gpu-pool -o wide

log_info "Checking EC2NodeClass status..."
kubectl get ec2nodeclass gpu-class -o wide

log_success "Karpenter configuration complete"
step_end
