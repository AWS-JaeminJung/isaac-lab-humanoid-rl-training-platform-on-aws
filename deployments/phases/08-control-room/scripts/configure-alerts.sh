#!/usr/bin/env bash
################################################################################
# configure-alerts.sh
#
# Configures Prometheus alert rules and Alertmanager routing:
#   1. Applies the PrometheusRule CRD manifest with GPU, training, and
#      infrastructure alert rules
#   2. Verifies alert rules are registered in Prometheus
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
# 1. Apply Prometheus Alert Rules
# ===========================================================================

step_start "Apply Prometheus alert rules"

kubectl apply -f "${MANIFESTS_DIR}/prometheus-alert-rules.yaml"

log_info "PrometheusRule manifest applied"
step_end

# ===========================================================================
# 2. Verify Alert Rules Registered in Prometheus
# ===========================================================================

step_start "Verify alert rules in Prometheus"

# Port-forward to Prometheus
PROM_LOCAL_PORT=19091
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

MAX_RETRIES=12
RETRY_INTERVAL=10
RETRY_COUNT=0

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    RULES_RESPONSE=$(curl -sf --max-time 10 \
        "http://localhost:${PROM_LOCAL_PORT}/api/v1/rules" 2>/dev/null || true)

    if [[ -n "${RULES_RESPONSE}" ]]; then
        # Check for our custom rule groups
        ISAAC_RULES=$(echo "${RULES_RESPONSE}" | \
            jq '[.data.groups[] | select(.name | startswith("isaac-lab"))] | length' 2>/dev/null || echo "0")

        if [[ "${ISAAC_RULES}" -gt 0 ]]; then
            log_success "Alert rules registered: ${ISAAC_RULES} isaac-lab rule group(s) found"
            break
        fi
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
        log_warn "Alert rules not yet visible in Prometheus after ${MAX_RETRIES} attempts"
        log_info "This may resolve after the next Prometheus rule reload cycle"
        break
    fi

    log_info "Waiting for alert rules to register (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep "${RETRY_INTERVAL}"
done

step_end

# ===========================================================================
# 3. Verify Alertmanager is Receiving Configuration
# ===========================================================================

step_start "Verify Alertmanager status"

# Port-forward to Alertmanager
AM_LOCAL_PORT=19093
kubectl port-forward svc/alertmanager-kube-prometheus-stack-alertmanager \
    -n "${MONITORING_NAMESPACE}" \
    "${AM_LOCAL_PORT}:9093" &
AM_PF_PID=$!

cleanup_am() {
    if kill -0 "${AM_PF_PID}" 2>/dev/null; then
        kill "${AM_PF_PID}" 2>/dev/null || true
        wait "${AM_PF_PID}" 2>/dev/null || true
    fi
    cleanup_pf
}
trap cleanup_am EXIT

sleep 3

AM_STATUS=$(curl -sf --max-time 10 \
    "http://localhost:${AM_LOCAL_PORT}/api/v2/status" 2>/dev/null || true)

if [[ -n "${AM_STATUS}" ]] && echo "${AM_STATUS}" | jq -e '.cluster' >/dev/null 2>&1; then
    log_success "Alertmanager is running and configured"
else
    log_warn "Could not verify Alertmanager status"
fi

# Clean up port-forwards
cleanup_am
trap - EXIT

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "Alert configuration complete"
log_info "PrometheusRule: isaac-lab-alerts applied to ${MONITORING_NAMESPACE}"
log_info "Alertmanager routing configured via kube-prometheus-stack Helm values"
