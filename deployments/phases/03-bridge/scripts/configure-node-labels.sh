#!/usr/bin/env bash
################################################################################
# configure-node-labels.sh
#
# Applies labels and taints to on-prem hybrid nodes:
#   Labels:  node-type=onprem-gpu, gpu-model=rtx-pro-6000
#   Taints:  workload-type=onprem-single-gpu:NoSchedule
#
# Hybrid nodes are identified by the instance-type label set by nodeadm
# during registration, or by a naming pattern (mi-*).
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

LABEL_NODE_TYPE="node-type=onprem-gpu"
LABEL_GPU_MODEL="gpu-model=rtx-pro-6000"
TAINT_WORKLOAD="workload-type=onprem-single-gpu:NoSchedule"

# ---------------------------------------------------------------------------
# Discover hybrid nodes
# ---------------------------------------------------------------------------

step_start "Discover hybrid nodes"

# Try multiple strategies to find hybrid nodes:
# 1. Nodes with eks.amazonaws.com/compute-type=hybrid label (set by nodeadm)
# 2. Nodes whose names start with "mi-" (SSM managed instance prefix)
HYBRID_NODES=""

HYBRID_NODES=$(kubectl get nodes \
    --selector='eks.amazonaws.com/compute-type=hybrid' \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)

if [[ -z "${HYBRID_NODES}" ]]; then
    log_info "No nodes found with eks.amazonaws.com/compute-type=hybrid, trying mi-* pattern..."
    HYBRID_NODES=$(kubectl get nodes --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
        | grep '^mi-' || true)
fi

if [[ -z "${HYBRID_NODES}" ]]; then
    log_warn "No hybrid nodes found in the cluster. Ensure nodes are registered first."
    log_info "Run register-hybrid-nodes.sh before this script."
    step_end 0
    exit 0
fi

NODE_COUNT=$(echo "${HYBRID_NODES}" | wc -l | tr -d ' ')
log_info "Found ${NODE_COUNT} hybrid node(s)"
echo "${HYBRID_NODES}" | while read -r node; do
    log_info "  - ${node}"
done

step_end

# ---------------------------------------------------------------------------
# Apply labels
# ---------------------------------------------------------------------------

step_start "Apply labels to hybrid nodes"

echo "${HYBRID_NODES}" | while read -r node; do
    if [[ -z "${node}" ]]; then continue; fi

    log_info "Labeling node: ${node}"
    kubectl label node "${node}" \
        "${LABEL_NODE_TYPE}" \
        "${LABEL_GPU_MODEL}" \
        --overwrite

    log_success "Labels applied to ${node}"
done

step_end

# ---------------------------------------------------------------------------
# Apply taints
# ---------------------------------------------------------------------------

step_start "Apply taints to hybrid nodes"

echo "${HYBRID_NODES}" | while read -r node; do
    if [[ -z "${node}" ]]; then continue; fi

    log_info "Tainting node: ${node}"
    kubectl taint node "${node}" \
        "${TAINT_WORKLOAD}" \
        --overwrite

    log_success "Taint applied to ${node}"
done

step_end

# ---------------------------------------------------------------------------
# Verify labels and taints
# ---------------------------------------------------------------------------

step_start "Verify labels and taints"

VERIFY_PASS=0
VERIFY_FAIL=0

echo "${HYBRID_NODES}" | while read -r node; do
    if [[ -z "${node}" ]]; then continue; fi

    log_info "Verifying node: ${node}"

    # Check labels
    NODE_LABELS=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels}')

    if echo "${NODE_LABELS}" | grep -q '"node-type":"onprem-gpu"'; then
        log_success "  Label node-type=onprem-gpu present"
    else
        log_error "  Label node-type=onprem-gpu MISSING"
    fi

    if echo "${NODE_LABELS}" | grep -q '"gpu-model":"rtx-pro-6000"'; then
        log_success "  Label gpu-model=rtx-pro-6000 present"
    else
        log_error "  Label gpu-model=rtx-pro-6000 MISSING"
    fi

    # Check taints
    NODE_TAINTS=$(kubectl get node "${node}" -o jsonpath='{.spec.taints}')

    if echo "${NODE_TAINTS}" | grep -q '"key":"workload-type"'; then
        log_success "  Taint workload-type=onprem-single-gpu:NoSchedule present"
    else
        log_error "  Taint workload-type=onprem-single-gpu:NoSchedule MISSING"
    fi
done

step_end

log_success "Node label and taint configuration complete"
