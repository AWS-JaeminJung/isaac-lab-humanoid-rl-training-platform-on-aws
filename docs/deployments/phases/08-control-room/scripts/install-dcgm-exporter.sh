#!/usr/bin/env bash
################################################################################
# install-dcgm-exporter.sh
#
# Deploys NVIDIA DCGM Exporter as a DaemonSet on GPU nodes:
#   - Applies the dcgm-exporter-daemonset.yaml manifest
#   - Verifies the DaemonSet is running on GPU nodes
#   - Checks that Prometheus is scraping DCGM metrics
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

MONITORING_NAMESPACE="$(get_tf_output monitoring_namespace)"

log_info "Namespace: ${MONITORING_NAMESPACE}"

# ===========================================================================
# 1. Apply DCGM Exporter DaemonSet
# ===========================================================================

step_start "Apply DCGM Exporter DaemonSet"

kubectl apply -f "${MANIFESTS_DIR}/dcgm-exporter-daemonset.yaml"

log_info "DCGM Exporter DaemonSet manifest applied"
step_end

# ===========================================================================
# 2. Verify DaemonSet is Running on GPU Nodes
# ===========================================================================

step_start "Verify DCGM Exporter DaemonSet"

MAX_WAIT=180
ELAPSED=0
POLL_INTERVAL=10

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    DESIRED=$(kubectl get daemonset dcgm-exporter \
        -n "${MONITORING_NAMESPACE}" \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(kubectl get daemonset dcgm-exporter \
        -n "${MONITORING_NAMESPACE}" \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

    if [[ "${DESIRED}" -gt 0 && "${READY}" -eq "${DESIRED}" ]]; then
        log_success "DCGM Exporter DaemonSet ready: ${READY}/${DESIRED} pods"
        break
    fi

    log_info "DCGM Exporter: ${READY}/${DESIRED} pods ready (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
    # DaemonSet may report 0 desired if no GPU nodes exist yet (Karpenter scaling)
    if [[ "${DESIRED}" -eq 0 ]]; then
        log_warn "No GPU nodes detected - DCGM Exporter DaemonSet has 0 desired pods"
        log_info "DaemonSet will schedule pods automatically when GPU nodes join the cluster"
    else
        die "DCGM Exporter DaemonSet did not become ready within ${MAX_WAIT}s (${READY}/${DESIRED})"
    fi
fi

step_end

# ===========================================================================
# 3. Verify Prometheus is Scraping DCGM Metrics
# ===========================================================================

step_start "Verify Prometheus scraping DCGM metrics"

# Only check if there are running DCGM pods
DCGM_PODS=$(kubectl get pods -n "${MONITORING_NAMESPACE}" \
    -l app=dcgm-exporter \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${DCGM_PODS}" -gt 0 ]]; then
    # Port-forward to Prometheus to check targets
    PROM_LOCAL_PORT=19090
    kubectl port-forward svc/prometheus-kube-prometheus-stack-prometheus \
        -n "${MONITORING_NAMESPACE}" \
        "${PROM_LOCAL_PORT}:9090" &
    PF_PID=$!

    cleanup_pf() {
        if kill -0 "${PF_PID}" 2>/dev/null; then
            kill "${PF_PID}" 2>/dev/null || true
            wait "${PF_PID}" 2>/dev/null || true
        fi
    }
    trap cleanup_pf EXIT

    sleep 3

    # Query Prometheus for DCGM metrics
    DCGM_METRICS=$(curl -sf --max-time 10 \
        "http://localhost:${PROM_LOCAL_PORT}/api/v1/query?query=DCGM_FI_DEV_GPU_TEMP" \
        2>/dev/null || true)

    if [[ -n "${DCGM_METRICS}" ]] && echo "${DCGM_METRICS}" | jq -e '.status == "success"' >/dev/null 2>&1; then
        log_success "Prometheus is scraping DCGM metrics"
    else
        log_warn "DCGM metrics not yet visible in Prometheus (may take a scrape interval)"
    fi

    # Clean up port-forward
    cleanup_pf
    trap - EXIT
else
    log_info "No DCGM Exporter pods running - skipping Prometheus scrape verification"
    log_info "DCGM metrics will be available once GPU nodes are scheduled"
fi

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "DCGM Exporter deployment complete"
log_info "Metrics endpoint: :9400/metrics on each GPU node"
