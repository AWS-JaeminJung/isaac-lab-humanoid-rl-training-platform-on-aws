#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 07 deployment:
#   - ClickHouse pod running
#   - ClickHouse HTTP API responds (curl :8123/ping -> "Ok.\n")
#   - 3 tables exist (SHOW TABLES)
#   - Test INSERT into training_metrics -> SELECT back
#   - Fluent Bit DaemonSet running on all nodes
#   - PVC mounted and correct size
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

LOGGING_NAMESPACE="$(get_tf_output logging_namespace)"
CLICKHOUSE_HOSTNAME="$(get_tf_output clickhouse_hostname)"

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

# ===========================================================================
# 1. ClickHouse Pod Running
# ===========================================================================

step_start "ClickHouse pods"

check "ClickHouse pods exist" \
    kubectl get pods -n "${LOGGING_NAMESPACE}" -l app=clickhouse -o name

READY_PODS=$(kubectl get pods -n "${LOGGING_NAMESPACE}" \
    -l app=clickhouse \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")
EXPECTED_PODS=1

if [[ "${READY_PODS}" -ge "${EXPECTED_PODS}" ]]; then
    log_success "PASS: ${READY_PODS}/${EXPECTED_PODS} ClickHouse pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${READY_PODS}/${EXPECTED_PODS} ClickHouse pod(s) Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 2. ClickHouse HTTP API Responds
# ===========================================================================

step_start "ClickHouse HTTP API"

CH_LOCAL_PORT=18123
kubectl port-forward svc/clickhouse \
    -n "${LOGGING_NAMESPACE}" \
    "${CH_LOCAL_PORT}:8123" &
PF_PID=$!

cleanup_pf() {
    if kill -0 "${PF_PID}" 2>/dev/null; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    fi
}
trap cleanup_pf EXIT

sleep 3

check "ClickHouse /ping returns Ok" \
    bash -c "curl -sf --max-time 10 'http://localhost:${CH_LOCAL_PORT}/ping' | grep -q 'Ok'"

check "ClickHouse HTTP API responds to SELECT 1" \
    bash -c "curl -sf --max-time 10 'http://localhost:${CH_LOCAL_PORT}/?query=SELECT+1' | grep -q '1'"

step_end

# ===========================================================================
# 3. Tables Exist (3 expected)
# ===========================================================================

step_start "ClickHouse tables"

TABLE_COUNT=$(kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
    clickhouse-client --query "SHOW TABLES" 2>/dev/null | wc -l | tr -d ' ')

if [[ "${TABLE_COUNT}" -ge 3 ]]; then
    log_success "PASS: ${TABLE_COUNT} table(s) found (expected >= 3)"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${TABLE_COUNT} table(s) found (expected >= 3)"
    FAIL=$((FAIL + 1))
fi

check "Table training_metrics exists" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query 'SHOW TABLES' | grep -q 'training_metrics'"

check "Table training_raw_logs exists" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query 'SHOW TABLES' | grep -q 'training_raw_logs'"

check "Table training_summary exists" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query 'SHOW TABLES' | grep -q 'training_summary'"

step_end

# ===========================================================================
# 4. Test INSERT + SELECT Round-Trip
# ===========================================================================

step_start "ClickHouse INSERT/SELECT round-trip"

TEST_WORKFLOW_ID="validate-$(date +%s)"

check "INSERT test row into training_metrics" \
    kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
        clickhouse-client --query "INSERT INTO training_metrics (timestamp, workflow_id, trial_id, sweep_id, task, iteration, mean_reward) VALUES (now(), '${TEST_WORKFLOW_ID}', 'trial-0', 'sweep-0', 'test-task', 1, 42.0)"

check "SELECT test row from training_metrics" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id = '${TEST_WORKFLOW_ID}'\" | grep -q '1'"

# Clean up test data
kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
    clickhouse-client --query "ALTER TABLE training_metrics DELETE WHERE workflow_id = '${TEST_WORKFLOW_ID}'" &>/dev/null || true

step_end

# ===========================================================================
# 5. Fluent Bit DaemonSet Running on All Nodes
# ===========================================================================

step_start "Fluent Bit DaemonSet"

check "Fluent Bit DaemonSet exists" \
    kubectl get daemonset fluent-bit -n "${LOGGING_NAMESPACE}"

DESIRED=$(kubectl get daemonset fluent-bit -n "${LOGGING_NAMESPACE}" \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
READY=$(kubectl get daemonset fluent-bit -n "${LOGGING_NAMESPACE}" \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [[ "${READY}" -ge "${DESIRED}" ]] && [[ "${DESIRED}" -gt 0 ]]; then
    log_success "PASS: Fluent Bit running on all ${DESIRED} node(s) (${READY}/${DESIRED} ready)"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Fluent Bit not ready on all nodes (${READY}/${DESIRED})"
    FAIL=$((FAIL + 1))
fi

check "Fluent Bit pods not in CrashLoopBackOff" \
    bash -c "! kubectl get pods -n '${LOGGING_NAMESPACE}' -l app=fluent-bit --no-headers | grep -q 'CrashLoopBackOff'"

step_end

# ===========================================================================
# 6. PVC Mounted and Correct Size
# ===========================================================================

step_start "ClickHouse PVC"

check "PVC data-clickhouse-0 exists" \
    kubectl get pvc data-clickhouse-0 -n "${LOGGING_NAMESPACE}"

check "PVC is Bound" \
    bash -c "kubectl get pvc data-clickhouse-0 -n '${LOGGING_NAMESPACE}' \
        -o jsonpath='{.status.phase}' | grep -q 'Bound'"

PVC_SIZE=$(kubectl get pvc data-clickhouse-0 -n "${LOGGING_NAMESPACE}" \
    -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "0")

if [[ "${PVC_SIZE}" == "50Gi" ]]; then
    log_success "PASS: PVC size is ${PVC_SIZE}"
    PASS=$((PASS + 1))
else
    log_error "FAIL: PVC size is ${PVC_SIZE}, expected 50Gi"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# Cleanup
# ===========================================================================

cleanup_pf
trap - EXIT

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 07 Validation Summary"
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
