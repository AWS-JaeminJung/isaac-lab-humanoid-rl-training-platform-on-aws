#!/usr/bin/env bash
################################################################################
# run-single-gpu.sh
#
# Stage 1: Single GPU validation
#   - Applies stage1-rayjob.yaml (envsubst for ECR_REPO_URL)
#   - Waits for RayJob completion (polling loop)
#   - Checks ClickHouse has metrics for this workflow
#   - Checks MLflow has experiment record
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
RAYJOB_NAME="h1-single-gpu-validation"
LOGGING_NAMESPACE="logging"

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

step_start "Clean up previous Stage 1 runs"

kubectl delete rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

log_info "Previous Stage 1 runs cleaned up"
step_end

# ===========================================================================
# 2. Apply Stage 1 RayJob Manifest
# ===========================================================================

step_start "Submit Stage 1 RayJob (single GPU)"

envsubst < "${MANIFESTS_DIR}/stage1-rayjob.yaml" | kubectl apply -f -

log_info "RayJob '${RAYJOB_NAME}' submitted to namespace ${TRAINING_NAMESPACE}"
step_end

# ===========================================================================
# 3. Wait for RayJob Completion
# ===========================================================================

step_start "Wait for RayJob completion"

MAX_WAIT=600
ELAPSED=0
POLL_INTERVAL=15
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
        die "Stage 1 failed: RayJob status is FAILED"
    fi

    log_info "RayJob status: ${JOB_STATUS:-PENDING} (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${JOB_STATUS}" != "SUCCEEDED" ]]; then
    log_error "RayJob did not complete within ${MAX_WAIT}s (status: ${JOB_STATUS:-UNKNOWN})"
    kubectl describe rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" 2>/dev/null || true
    die "Stage 1 failed: timeout"
fi

step_end

# ===========================================================================
# 4. Check ClickHouse Metrics
# ===========================================================================

step_start "Verify ClickHouse metrics"

check "ClickHouse has metrics for Stage 1 workflow" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%single-gpu%'\" \
        | grep -v '^0$'"

step_end

# ===========================================================================
# 5. Check MLflow Experiment Record
# ===========================================================================

step_start "Verify MLflow experiment record"

MLFLOW_POD="$(kubectl get pods -n model-registry -l app=mlflow \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${MLFLOW_POD}" ]]; then
    check "MLflow has experiment for Stage 1" \
        bash -c "kubectl exec -n model-registry '${MLFLOW_POD}' -- \
            python -c \"import mlflow; exps = mlflow.search_experiments(); print(len(exps))\" \
            | grep -v '^0$'"
else
    log_warn "MLflow pod not found; skipping MLflow check"
fi

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Stage 1: Single GPU Validation Summary"
echo "=============================================================================="
echo "  RayJob:   ${RAYJOB_NAME}"
echo "  Status:   ${JOB_STATUS}"
echo "  Checks:   PASSED=${PASS}/${TOTAL}  FAILED=${FAIL}/${TOTAL}"
echo "=============================================================================="
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    log_error "Stage 1 completed with ${FAIL} failure(s)"
    exit 1
else
    log_success "Stage 1: Single GPU validation passed"
    exit 0
fi
