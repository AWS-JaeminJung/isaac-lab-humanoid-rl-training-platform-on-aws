#!/usr/bin/env bash
################################################################################
# install-fluentbit.sh
#
# Deploys Fluent Bit as a Kubernetes DaemonSet:
#   - Applies fluentbit-configmap.yaml and fluentbit-daemonset.yaml
#   - Waits for the DaemonSet rollout to complete
#   - Verifies pods running on nodes
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
MANIFESTS_DIR="${PHASE_DIR}/manifests"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"
# shellcheck source=../../../../lib/helm.sh
source "${SCRIPT_DIR}/../../../lib/helm.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

LOGGING_NAMESPACE="$(get_tf_output logging_namespace)"

log_info "Namespace: ${LOGGING_NAMESPACE}"

# ===========================================================================
# 1. Apply Fluent Bit ConfigMap
# ===========================================================================

step_start "Apply Fluent Bit ConfigMap"

kubectl apply -f "${MANIFESTS_DIR}/fluentbit-configmap.yaml"

log_info "Fluent Bit ConfigMap manifest applied"
step_end

# ===========================================================================
# 2. Apply Fluent Bit DaemonSet
# ===========================================================================

step_start "Apply Fluent Bit DaemonSet"

kubectl apply -f "${MANIFESTS_DIR}/fluentbit-daemonset.yaml"

log_info "Fluent Bit DaemonSet manifest applied"
step_end

# ===========================================================================
# 3. Wait for DaemonSet Rollout
# ===========================================================================

step_start "Wait for Fluent Bit DaemonSet to be ready"

MAX_WAIT=180
log_info "Waiting up to ${MAX_WAIT}s for fluent-bit daemonset to roll out..."

if kubectl rollout status daemonset/fluent-bit \
    -n "${LOGGING_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "Fluent Bit DaemonSet is ready"
else
    die "Fluent Bit DaemonSet did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# 4. Verify Pods Running on Nodes
# ===========================================================================

step_start "Verify Fluent Bit pods running on nodes"

DESIRED=$(kubectl get daemonset fluent-bit -n "${LOGGING_NAMESPACE}" \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
READY=$(kubectl get daemonset fluent-bit -n "${LOGGING_NAMESPACE}" \
    -o jsonpath='{.status.numberReady}' 2>/dev/null)

log_info "Fluent Bit pods: ${READY}/${DESIRED} ready"

if [[ "${READY}" -ge "${DESIRED}" ]] && [[ "${DESIRED}" -gt 0 ]]; then
    log_success "Fluent Bit running on all ${DESIRED} node(s)"
else
    die "Fluent Bit not ready on all nodes: ${READY}/${DESIRED}"
fi

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "Fluent Bit deployment complete"
log_info "DaemonSet running on ${DESIRED} node(s) in namespace ${LOGGING_NAMESPACE}"
