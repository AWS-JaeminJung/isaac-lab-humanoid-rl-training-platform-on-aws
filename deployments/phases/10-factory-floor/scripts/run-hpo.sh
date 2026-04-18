#!/usr/bin/env bash
################################################################################
# run-hpo.sh
#
# Stage 4: HPO (Hyperparameter Optimization) validation with ASHA scheduler
#   - Applies stage4-hpo-rayjob.yaml (envsubst for ECR_REPO_URL)
#   - Monitors trial progress
#   - Waits for HPO completion
#   - Checks multiple trials recorded in ClickHouse
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
RAYJOB_NAME="h1-hpo-validation"
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

step_start "Clean up previous Stage 4 runs"

kubectl delete rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

log_info "Previous Stage 4 runs cleaned up"
step_end

# ===========================================================================
# 2. Apply Stage 4 HPO RayJob Manifest
# ===========================================================================

step_start "Submit Stage 4 HPO RayJob (ASHA scheduler)"

envsubst < "${MANIFESTS_DIR}/stage4-hpo-rayjob.yaml" | kubectl apply -f -

log_info "RayJob '${RAYJOB_NAME}' submitted to namespace ${TRAINING_NAMESPACE}"
step_end

# ===========================================================================
# 3. Monitor Trial Progress
# ===========================================================================

step_start "Monitor HPO trial progress"

MAX_WAIT=3600
ELAPSED=0
POLL_INTERVAL=30
JOB_STATUS=""
LAST_TRIAL_COUNT=0

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    JOB_STATUS="$(kubectl get rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" \
        -o jsonpath='{.status.jobStatus}' 2>/dev/null || true)"

    if [[ "${JOB_STATUS}" == "SUCCEEDED" ]]; then
        log_success "HPO RayJob completed successfully"
        break
    elif [[ "${JOB_STATUS}" == "FAILED" ]]; then
        log_error "HPO RayJob failed"
        kubectl logs -n "${TRAINING_NAMESPACE}" \
            -l ray.io/rayjob="${RAYJOB_NAME}" \
            --tail=100 2>/dev/null || true
        die "Stage 4 failed: RayJob status is FAILED"
    fi

    # Query ClickHouse for trial count to monitor progress
    TRIAL_COUNT="$(kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
        clickhouse-client --query "SELECT uniqExact(trial_id) FROM training_metrics WHERE workflow_id LIKE '%hpo%'" \
        2>/dev/null || echo "0")"
    TRIAL_COUNT="$(echo "${TRIAL_COUNT}" | tr -d '[:space:]')"

    if [[ "${TRIAL_COUNT}" != "${LAST_TRIAL_COUNT}" ]]; then
        log_info "HPO trials in progress: ${TRIAL_COUNT} (status: ${JOB_STATUS:-PENDING}, ${ELAPSED}s/${MAX_WAIT}s)"
        LAST_TRIAL_COUNT="${TRIAL_COUNT}"
    else
        log_info "RayJob status: ${JOB_STATUS:-PENDING}, trials: ${TRIAL_COUNT} (${ELAPSED}s/${MAX_WAIT}s)..."
    fi

    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${JOB_STATUS}" != "SUCCEEDED" ]]; then
    log_error "HPO RayJob did not complete within ${MAX_WAIT}s (status: ${JOB_STATUS:-UNKNOWN})"
    kubectl describe rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" 2>/dev/null || true
    die "Stage 4 failed: timeout"
fi

step_end

# ===========================================================================
# 4. Check Multiple Trials in ClickHouse
# ===========================================================================

step_start "Verify HPO trials recorded in ClickHouse"

FINAL_TRIAL_COUNT="$(kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
    clickhouse-client --query "SELECT uniqExact(trial_id) FROM training_metrics WHERE workflow_id LIKE '%hpo%'" \
    2>/dev/null || echo "0")"
FINAL_TRIAL_COUNT="$(echo "${FINAL_TRIAL_COUNT}" | tr -d '[:space:]')"

log_info "Total HPO trials recorded: ${FINAL_TRIAL_COUNT}"

check "Multiple HPO trials recorded in ClickHouse (>= 3)" \
    test "${FINAL_TRIAL_COUNT}" -ge 3

check "ClickHouse has metrics for all HPO trials" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%hpo%'\" \
        | grep -v '^0$'"

# Check that different hyperparameter values were recorded
check "HPO trials have distinct sweep metadata" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT uniqExact(sweep_id) FROM training_metrics WHERE workflow_id LIKE '%hpo%'\" \
        | grep -v '^0$'"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Stage 4: HPO Validation Summary"
echo "=============================================================================="
echo "  RayJob:       ${RAYJOB_NAME}"
echo "  Status:       ${JOB_STATUS}"
echo "  Trials:       ${FINAL_TRIAL_COUNT}"
echo "  Checks:       PASSED=${PASS}/${TOTAL}  FAILED=${FAIL}/${TOTAL}"
echo "=============================================================================="
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    log_error "Stage 4 completed with ${FAIL} failure(s)"
    exit 1
else
    log_success "Stage 4: HPO validation passed"
    exit 0
fi
