#!/usr/bin/env bash
################################################################################
# run-multi-gpu.sh
#
# Stage 2: Multi-GPU validation (8 GPUs, single node)
#   - Applies stage2-rayjob.yaml (envsubst for ECR_REPO_URL)
#   - Waits for RayJob completion
#   - Checks GPU utilization was high (via ClickHouse or Prometheus)
#   - Reports pass/fail
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS_DIR="${PHASE_DIR}/manifests"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

PLATFORM_TERRAFORM_DIR="${PHASE_DIR}/../02-platform/terraform"

get_tf_output() {
    terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

export ECR_REPO_URL
ECR_REPO_URL="$(get_tf_output ecr_repository_url)"

TRAINING_NAMESPACE="training"
RAYJOB_NAME="h1-multi-gpu-validation"
LOGGING_NAMESPACE="logging"
MONITORING_NAMESPACE="monitoring"

log_info "ECR Repository URL: ${ECR_REPO_URL}"
log_info "Training namespace: ${TRAINING_NAMESPACE}"

PASS=0
FAIL=0

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
# 1. Clean Up Previous Run
# ===========================================================================

step_start "Clean up previous Stage 2 runs"

kubectl delete rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

log_info "Previous Stage 2 runs cleaned up"
step_end

# ===========================================================================
# 2. Apply Stage 2 RayJob Manifest
# ===========================================================================

step_start "Submit Stage 2 RayJob (multi-GPU, 8 GPUs)"

envsubst < "${MANIFESTS_DIR}/stage2-rayjob.yaml" | kubectl apply -f -

log_info "RayJob '${RAYJOB_NAME}' submitted to namespace ${TRAINING_NAMESPACE}"
step_end

# ===========================================================================
# 3. Wait for RayJob Completion
# ===========================================================================

step_start "Wait for RayJob completion"

MAX_WAIT=1800
ELAPSED=0
POLL_INTERVAL=30
JOB_STATUS=""

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    JOB_STATUS="$(kubectl get rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" \
        -o jsonpath='{.status.jobStatus}' 2>/dev/null || true)"

    if [[ "${JOB_STATUS}" == "SUCCEEDED" ]]; then
        log_success "RayJob completed successfully"
        break
    elif [[ "${JOB_STATUS}" == "FAILED" ]]; then
        log_error "RayJob failed"
        kubectl logs -n "${TRAINING_NAMESPACE}" \
            -l ray.io/rayjob="${RAYJOB_NAME}" \
            --tail=50 2>/dev/null || true
        die "Stage 2 failed: RayJob status is FAILED"
    fi

    log_info "RayJob status: ${JOB_STATUS:-PENDING} (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${JOB_STATUS}" != "SUCCEEDED" ]]; then
    log_error "RayJob did not complete within ${MAX_WAIT}s (status: ${JOB_STATUS:-UNKNOWN})"
    kubectl describe rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" 2>/dev/null || true
    die "Stage 2 failed: timeout"
fi

step_end

# ===========================================================================
# 4. Check GPU Utilization
# ===========================================================================

step_start "Verify GPU utilization"

# Check via ClickHouse metrics
check "ClickHouse has metrics for Stage 2 workflow" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%multi-gpu%'\" \
        | grep -v '^0$'"

# Check via Prometheus (DCGM exporter) that GPU utilization was above 50%
PROM_POD="$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${PROM_POD}" ]]; then
    check "GPU utilization exceeded 50% during training" \
        bash -c "kubectl exec -n '${MONITORING_NAMESPACE}' '${PROM_POD}' -- \
            wget -qO- 'http://localhost:9090/api/v1/query?query=max_over_time(DCGM_FI_DEV_GPU_UTIL[30m])' \
            | python3 -c 'import sys,json; d=json.load(sys.stdin); v=float(d[\"data\"][\"result\"][0][\"value\"][1]); sys.exit(0 if v>50 else 1)'"
else
    log_warn "Prometheus pod not found; skipping GPU utilization check"
fi

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Stage 2: Multi-GPU Validation Summary"
echo "=============================================================================="
echo "  RayJob:   ${RAYJOB_NAME}"
echo "  GPUs:     8 (single node)"
echo "  Status:   ${JOB_STATUS}"
echo "  Checks:   PASSED=${PASS}/${TOTAL}  FAILED=${FAIL}/${TOTAL}"
echo "=============================================================================="
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    log_error "Stage 2 completed with ${FAIL} failure(s)"
    exit 1
else
    log_success "Stage 2: Multi-GPU validation passed"
    exit 0
fi
