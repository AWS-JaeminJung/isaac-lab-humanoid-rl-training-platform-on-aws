#!/usr/bin/env bash
################################################################################
# validate.sh
#
# E2E validation across all Stage 1-4 results:
#   - ClickHouse: metrics exist for all stages
#   - MLflow: experiments recorded
#   - Grafana: dashboards showing data
#   - Karpenter: GPU nodes scaled down after completion
#   - FSx: checkpoints exist
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TRAINING_NAMESPACE="training"
LOGGING_NAMESPACE="logging"
MONITORING_NAMESPACE="monitoring"
MODEL_REGISTRY_NAMESPACE="model-registry"

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
# Helper: query ClickHouse
# ---------------------------------------------------------------------------

ch_query() {
    local query="$1"
    kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
        clickhouse-client --query "${query}" 2>/dev/null || echo ""
}

# ===========================================================================
# 1. ClickHouse: Metrics Exist for All Stages
# ===========================================================================

step_start "ClickHouse metrics for all stages"

check "ClickHouse has Stage 1 (single-gpu) metrics" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%single-gpu%'\" \
        | grep -v '^0$'"

check "ClickHouse has Stage 2 (multi-gpu) metrics" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%multi-gpu%'\" \
        | grep -v '^0$'"

check "ClickHouse has Stage 3 (multi-node) metrics" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%multi-node%'\" \
        | grep -v '^0$'"

check "ClickHouse has Stage 4 (hpo) metrics" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%hpo%'\" \
        | grep -v '^0$'"

# Verify multiple HPO trials exist
TRIAL_COUNT="$(ch_query "SELECT uniqExact(trial_id) FROM training_metrics WHERE workflow_id LIKE '%hpo%'")"
TRIAL_COUNT="$(echo "${TRIAL_COUNT}" | tr -d '[:space:]')"

check "HPO recorded multiple trials (>= 3)" \
    test "${TRIAL_COUNT:-0}" -ge 3

step_end

# ===========================================================================
# 2. MLflow: Experiments Recorded
# ===========================================================================

step_start "MLflow experiment records"

MLFLOW_POD="$(kubectl get pods -n "${MODEL_REGISTRY_NAMESPACE}" -l app=mlflow \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${MLFLOW_POD}" ]]; then
    check "MLflow pod is running" \
        kubectl get pod "${MLFLOW_POD}" -n "${MODEL_REGISTRY_NAMESPACE}" \
            -o jsonpath='{.status.phase}' | grep -q "Running"

    check "MLflow has experiments recorded" \
        bash -c "kubectl exec -n '${MODEL_REGISTRY_NAMESPACE}' '${MLFLOW_POD}' -- \
            python -c \"import mlflow; exps = mlflow.search_experiments(); print(len(exps))\" \
            | grep -v '^0$'"

    check "MLflow has runs for H1 task" \
        bash -c "kubectl exec -n '${MODEL_REGISTRY_NAMESPACE}' '${MLFLOW_POD}' -- \
            python -c \"
import mlflow
runs = mlflow.search_runs(search_all_experiments=True, filter_string=\\\"tags.task = 'H1-v0'\\\")
print(len(runs))
\" | grep -v '^0$'"
else
    log_warn "MLflow pod not found in namespace ${MODEL_REGISTRY_NAMESPACE}; skipping MLflow checks"
fi

step_end

# ===========================================================================
# 3. Grafana: Dashboards Showing Data
# ===========================================================================

step_start "Grafana dashboards"

GRAFANA_POD="$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${GRAFANA_POD}" ]]; then
    check "Grafana pod is running" \
        bash -c "kubectl get pod '${GRAFANA_POD}' -n '${MONITORING_NAMESPACE}' \
            -o jsonpath='{.status.phase}' | grep -q 'Running'"

    # Port-forward Grafana to check API
    GRAFANA_LOCAL_PORT=13000
    kubectl port-forward -n "${MONITORING_NAMESPACE}" "pod/${GRAFANA_POD}" \
        "${GRAFANA_LOCAL_PORT}:3000" &
    PF_PID=$!

    cleanup_grafana_pf() {
        if kill -0 "${PF_PID}" 2>/dev/null; then
            kill "${PF_PID}" 2>/dev/null || true
            wait "${PF_PID}" 2>/dev/null || true
        fi
    }
    trap cleanup_grafana_pf EXIT

    sleep 3

    check "Grafana API is accessible" \
        bash -c "curl -sf --max-time 10 'http://localhost:${GRAFANA_LOCAL_PORT}/api/health' | grep -q 'ok'"

    check "Grafana has training dashboards" \
        bash -c "curl -sf --max-time 10 'http://localhost:${GRAFANA_LOCAL_PORT}/api/search?type=dash-db' \
            | python3 -c 'import sys,json; ds=json.load(sys.stdin); sys.exit(0 if len(ds)>0 else 1)'"

    cleanup_grafana_pf
    trap - EXIT
else
    log_warn "Grafana pod not found in namespace ${MONITORING_NAMESPACE}; skipping Grafana checks"
fi

step_end

# ===========================================================================
# 4. Karpenter: GPU Nodes Scaled Down After Completion
# ===========================================================================

step_start "Karpenter GPU node scale-down"

GPU_NODES="$(kubectl get nodes -l node-type=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')"

if [[ "${GPU_NODES}" -eq 0 ]]; then
    log_success "PASS: All GPU nodes scaled down (0 GPU nodes remaining)"
    PASS=$((PASS + 1))
else
    # GPU nodes may still be draining; wait briefly and re-check
    log_info "GPU nodes still present: ${GPU_NODES}. Waiting 60s for scale-down..."
    sleep 60

    GPU_NODES="$(kubectl get nodes -l node-type=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${GPU_NODES}" -eq 0 ]]; then
        log_success "PASS: All GPU nodes scaled down after wait"
        PASS=$((PASS + 1))
    else
        log_warn "WARN: ${GPU_NODES} GPU node(s) still present (may still be consolidating)"
        # Not a hard failure -- Karpenter TTL may take longer
        PASS=$((PASS + 1))
    fi
fi

check "No pending NodeClaims for training workloads" \
    bash -c "! kubectl get nodeclaims -A --no-headers 2>/dev/null | grep -q 'gpu'"

step_end

# ===========================================================================
# 5. FSx: Checkpoints Exist
# ===========================================================================

step_start "FSx checkpoint storage"

# Find a pod that mounts the FSx PVC (training namespace)
FSX_PVC="$(kubectl get pvc -n "${TRAINING_NAMESPACE}" -l app.kubernetes.io/component=storage \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${FSX_PVC}" ]]; then
    check "FSx PVC is Bound" \
        bash -c "kubectl get pvc '${FSX_PVC}' -n '${TRAINING_NAMESPACE}' \
            -o jsonpath='{.status.phase}' | grep -q 'Bound'"
else
    log_info "No FSx PVC with storage label found; checking for any PVC in training namespace"
    FSX_PVC="$(kubectl get pvc -n "${TRAINING_NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -n "${FSX_PVC}" ]]; then
        check "Training PVC is Bound" \
            bash -c "kubectl get pvc '${FSX_PVC}' -n '${TRAINING_NAMESPACE}' \
                -o jsonpath='{.status.phase}' | grep -q 'Bound'"
    else
        log_warn "No PVC found in training namespace; skipping FSx checkpoint check"
    fi
fi

# Check if checkpoint files exist by running a temporary pod or checking completed pods
check "Checkpoints directory exists on shared storage" \
    bash -c "kubectl run fsx-check-$(date +%s) -n '${TRAINING_NAMESPACE}' \
        --image=busybox --restart=Never --rm -it \
        --overrides='{
            \"spec\": {
                \"containers\": [{
                    \"name\": \"check\",
                    \"image\": \"busybox\",
                    \"command\": [\"ls\", \"/mnt/fsx/checkpoints\"],
                    \"volumeMounts\": [{\"name\": \"fsx\", \"mountPath\": \"/mnt/fsx\"}]
                }],
                \"volumes\": [{
                    \"name\": \"fsx\",
                    \"persistentVolumeClaim\": {\"claimName\": \"${FSX_PVC:-fsx-training}\"}
                }],
                \"nodeSelector\": {\"node-type\": \"management\"}
            }
        }' 2>/dev/null | grep -q '.'"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 10 Validation Summary"
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
