#!/usr/bin/env bash
################################################################################
# install-device-plugin.sh
#
# Deploys the NVIDIA Device Plugin DaemonSet to on-prem hybrid GPU nodes.
# The manifest uses a nodeSelector (node-type=onprem-gpu) and tolerations
# so it only runs on registered on-prem machines.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS_DIR="${PHASE_DIR}/manifests"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

DEVICE_PLUGIN_MANIFEST="${MANIFESTS_DIR}/nvidia-device-plugin.yaml"

if [[ ! -f "${DEVICE_PLUGIN_MANIFEST}" ]]; then
    die "NVIDIA Device Plugin manifest not found: ${DEVICE_PLUGIN_MANIFEST}"
fi

# ---------------------------------------------------------------------------
# Apply NVIDIA Device Plugin DaemonSet
# ---------------------------------------------------------------------------

step_start "Apply NVIDIA Device Plugin DaemonSet"

log_info "Applying manifest: ${DEVICE_PLUGIN_MANIFEST}"
kubectl apply -f "${DEVICE_PLUGIN_MANIFEST}"

log_success "NVIDIA Device Plugin DaemonSet applied"
step_end

# ---------------------------------------------------------------------------
# Wait for DaemonSet to be ready
# ---------------------------------------------------------------------------

step_start "Wait for DaemonSet rollout"

NAMESPACE="kube-system"
DAEMONSET_NAME="nvidia-device-plugin-onprem"

log_info "Waiting for DaemonSet ${DAEMONSET_NAME} to be ready..."

# Wait for the DaemonSet to exist
retry 5 3 kubectl get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}"

# Wait for rollout
MAX_WAIT=300
INTERVAL=10
ELAPSED=0

while (( ELAPSED < MAX_WAIT )); do
    DESIRED=$(kubectl get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(kubectl get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

    if [[ "${DESIRED}" -gt 0 ]] && [[ "${READY}" -ge "${DESIRED}" ]]; then
        log_success "DaemonSet ${DAEMONSET_NAME}: ${READY}/${DESIRED} pods ready"
        break
    fi

    log_info "DaemonSet ${DAEMONSET_NAME}: ${READY}/${DESIRED} pods ready, waiting ${INTERVAL}s..."
    sleep "${INTERVAL}"
    ELAPSED=$(( ELAPSED + INTERVAL ))
done

if (( ELAPSED >= MAX_WAIT )); then
    log_warn "Timed out waiting for DaemonSet rollout. Current status:"
    kubectl get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" -o wide
    kubectl get pods -n "${NAMESPACE}" -l app=nvidia-device-plugin-onprem -o wide
fi

step_end

# ---------------------------------------------------------------------------
# Show status
# ---------------------------------------------------------------------------

step_start "Device plugin status"

log_info "DaemonSet status:"
kubectl get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" -o wide

log_info "Device plugin pods:"
kubectl get pods -n "${NAMESPACE}" -l app=nvidia-device-plugin-onprem -o wide

step_end

log_success "NVIDIA Device Plugin installation complete"
