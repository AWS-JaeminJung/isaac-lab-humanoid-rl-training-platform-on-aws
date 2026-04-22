#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 08 deployment:
#   - Prometheus running, scraping targets
#   - Grafana accessible (https://grafana.${domain})
#   - DCGM Exporter running on GPU nodes
#   - Prometheus data source connected
#   - ClickHouse data source connected
#   - Dashboards loaded
#   - Alert rules registered
#   - Alertmanager running
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

MONITORING_NAMESPACE="$(get_tf_output monitoring_namespace)"
GRAFANA_HOSTNAME="$(get_tf_output grafana_hostname)"
GRAFANA_URL="https://${GRAFANA_HOSTNAME}"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper: check result
# ---------------------------------------------------------------------------

check() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        log_success "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        log_error "FAIL: ${name}"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# Retrieve Grafana admin credentials
# ---------------------------------------------------------------------------

GRAFANA_USER="$(kubectl get secret grafana-admin-credentials \
    -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")"
GRAFANA_PASSWORD="$(kubectl get secret grafana-admin-credentials \
    -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")"
GRAFANA_AUTH="${GRAFANA_USER}:${GRAFANA_PASSWORD}"

# ===========================================================================
# 1. Prometheus Running
# ===========================================================================

step_start "Prometheus pods"

check "Prometheus StatefulSet exists" \
    kubectl get statefulset prometheus-kube-prometheus-stack-prometheus \
        -n "${MONITORING_NAMESPACE}"

PROM_READY=$(kubectl get pods -n "${MONITORING_NAMESPACE}" \
    -l app.kubernetes.io/name=prometheus \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${PROM_READY}" -ge 1 ]]; then
    log_success "PASS: ${PROM_READY} Prometheus pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: No Prometheus pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 2. Prometheus Scraping Targets
# ===========================================================================

step_start "Prometheus scraping targets"

PROM_LOCAL_PORT=19092
kubectl port-forward svc/prometheus-kube-prometheus-stack-prometheus \
    -n "${MONITORING_NAMESPACE}" \
    "${PROM_LOCAL_PORT}:9090" &
PROM_PF_PID=$!

cleanup_prom_pf() {
    if kill -0 "${PROM_PF_PID}" 2>/dev/null; then
        kill "${PROM_PF_PID}" 2>/dev/null || true
        wait "${PROM_PF_PID}" 2>/dev/null || true
    fi
}

sleep 3

TARGETS_RESPONSE=$(curl -sf --max-time 10 \
    "http://localhost:${PROM_LOCAL_PORT}/api/v1/targets" 2>/dev/null || true)

if [[ -n "${TARGETS_RESPONSE}" ]]; then
    ACTIVE_TARGETS=$(echo "${TARGETS_RESPONSE}" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")
    if [[ "${ACTIVE_TARGETS}" -gt 0 ]]; then
        log_success "PASS: Prometheus scraping ${ACTIVE_TARGETS} active target(s)"
        PASS=$((PASS + 1))
    else
        log_error "FAIL: Prometheus has no active scrape targets"
        FAIL=$((FAIL + 1))
    fi
else
    log_error "FAIL: Could not query Prometheus targets API"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 3. Grafana Accessible
# ===========================================================================

step_start "Grafana accessible"

check "Grafana URL returns 200/302" \
    curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "${GRAFANA_URL}/"

check "Grafana DNS resolves ${GRAFANA_HOSTNAME}" \
    nslookup "${GRAFANA_HOSTNAME}"

step_end

# ===========================================================================
# 4. DCGM Exporter Running on GPU Nodes
# ===========================================================================

step_start "DCGM Exporter"

check "DCGM Exporter DaemonSet exists" \
    kubectl get daemonset dcgm-exporter -n "${MONITORING_NAMESPACE}"

DCGM_DESIRED=$(kubectl get daemonset dcgm-exporter \
    -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
DCGM_READY=$(kubectl get daemonset dcgm-exporter \
    -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [[ "${DCGM_DESIRED}" -eq 0 ]]; then
    log_info "INFO: DCGM Exporter has 0 desired pods (no GPU nodes present)"
    PASS=$((PASS + 1))
elif [[ "${DCGM_READY}" -eq "${DCGM_DESIRED}" ]]; then
    log_success "PASS: DCGM Exporter ${DCGM_READY}/${DCGM_DESIRED} pods ready"
    PASS=$((PASS + 1))
else
    log_error "FAIL: DCGM Exporter ${DCGM_READY}/${DCGM_DESIRED} pods ready"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 5. Grafana Data Sources via API
# ===========================================================================

step_start "Grafana data sources"

# Port-forward to Grafana
GRAFANA_LOCAL_PORT=13001
kubectl port-forward svc/kube-prometheus-stack-grafana \
    -n "${MONITORING_NAMESPACE}" \
    "${GRAFANA_LOCAL_PORT}:80" &
GRAFANA_PF_PID=$!

cleanup_grafana_pf() {
    if kill -0 "${GRAFANA_PF_PID}" 2>/dev/null; then
        kill "${GRAFANA_PF_PID}" 2>/dev/null || true
        wait "${GRAFANA_PF_PID}" 2>/dev/null || true
    fi
}

sleep 3

GRAFANA_LOCAL_API="http://localhost:${GRAFANA_LOCAL_PORT}/api"

# Check Prometheus data source
PROM_DS=$(curl -sf --max-time 10 \
    -u "${GRAFANA_AUTH}" \
    "${GRAFANA_LOCAL_API}/datasources/name/Prometheus" 2>/dev/null || true)

if [[ -n "${PROM_DS}" ]] && echo "${PROM_DS}" | jq -e '.id' >/dev/null 2>&1; then
    log_success "PASS: Prometheus data source connected"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Prometheus data source not found"
    FAIL=$((FAIL + 1))
fi

# Check ClickHouse data source
CH_DS=$(curl -sf --max-time 10 \
    -u "${GRAFANA_AUTH}" \
    "${GRAFANA_LOCAL_API}/datasources/name/ClickHouse" 2>/dev/null || true)

if [[ -n "${CH_DS}" ]] && echo "${CH_DS}" | jq -e '.id' >/dev/null 2>&1; then
    log_success "PASS: ClickHouse data source connected"
    PASS=$((PASS + 1))
else
    log_error "FAIL: ClickHouse data source not found"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 6. Dashboards Loaded
# ===========================================================================

step_start "Grafana dashboards"

SEARCH_RESPONSE=$(curl -sf --max-time 10 \
    -u "${GRAFANA_AUTH}" \
    "${GRAFANA_LOCAL_API}/search?type=dash-db" 2>/dev/null || true)

DASHBOARD_COUNT=0
if [[ -n "${SEARCH_RESPONSE}" ]]; then
    DASHBOARD_COUNT=$(echo "${SEARCH_RESPONSE}" | jq 'length' 2>/dev/null || echo "0")
fi

EXPECTED_DASHBOARDS=4
if [[ "${DASHBOARD_COUNT}" -ge "${EXPECTED_DASHBOARDS}" ]]; then
    log_success "PASS: ${DASHBOARD_COUNT} dashboards loaded (expected >= ${EXPECTED_DASHBOARDS})"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${DASHBOARD_COUNT} dashboards found (expected >= ${EXPECTED_DASHBOARDS})"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 7. Alert Rules Registered
# ===========================================================================

step_start "Alert rules"

RULES_RESPONSE=$(curl -sf --max-time 10 \
    "http://localhost:${PROM_LOCAL_PORT}/api/v1/rules" 2>/dev/null || true)

if [[ -n "${RULES_RESPONSE}" ]]; then
    ISAAC_RULES=$(echo "${RULES_RESPONSE}" | \
        jq '[.data.groups[] | select(.name | startswith("isaac-lab"))] | length' 2>/dev/null || echo "0")

    if [[ "${ISAAC_RULES}" -gt 0 ]]; then
        log_success "PASS: ${ISAAC_RULES} isaac-lab alert rule group(s) registered"
        PASS=$((PASS + 1))
    else
        log_error "FAIL: No isaac-lab alert rule groups found in Prometheus"
        FAIL=$((FAIL + 1))
    fi
else
    log_error "FAIL: Could not query Prometheus rules API"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 8. Alertmanager Running
# ===========================================================================

step_start "Alertmanager"

check "Alertmanager StatefulSet exists" \
    kubectl get statefulset alertmanager-kube-prometheus-stack-alertmanager \
        -n "${MONITORING_NAMESPACE}"

AM_READY=$(kubectl get pods -n "${MONITORING_NAMESPACE}" \
    -l app.kubernetes.io/name=alertmanager \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${AM_READY}" -ge 1 ]]; then
    log_success "PASS: ${AM_READY} Alertmanager pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: No Alertmanager pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 9. Ingress and DNS
# ===========================================================================

step_start "Ingress and DNS"

check "Grafana Ingress exists" \
    kubectl get ingress grafana -n "${MONITORING_NAMESPACE}"

check "Ingress has ALB address" \
    kubectl get ingress grafana -n "${MONITORING_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

step_end

# ===========================================================================
# Cleanup port-forwards
# ===========================================================================

cleanup_prom_pf
cleanup_grafana_pf

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 08 Validation Summary"
echo "=============================================================================="
echo "  PASSED: ${PASS}/${TOTAL}"
echo "  FAILED: ${FAIL}/${TOTAL}"
echo "=============================================================================="
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    log_error "Validation completed with ${FAIL} failure(s)"
    exit 1
else
    log_success "All validation checks passed"
    exit 0
fi
