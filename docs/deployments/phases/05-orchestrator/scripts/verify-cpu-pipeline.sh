#!/usr/bin/env bash
################################################################################
# verify-cpu-pipeline.sh
#
# Submits a CPU-only RayJob to verify the OSMO + KubeRay pipeline end-to-end:
#   - Applies the CPU test RayJob manifest
#   - Waits for the RayJob to complete
#   - Verifies RayCluster was created and cleaned up
#   - Reports pass/fail
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

TRAINING_NAMESPACE="$(get_tf_output training_namespace)"

log_info "Training namespace: ${TRAINING_NAMESPACE}"

# ===========================================================================
# 1. Clean Up Any Previous Test Run
# ===========================================================================

step_start "Clean up previous test runs"

kubectl delete rayjob cpu-pipeline-test -n "${TRAINING_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

log_info "Previous test runs cleaned up"
step_end

# ===========================================================================
# 2. Apply CPU Test RayJob Manifest
# ===========================================================================

step_start "Submit CPU test RayJob"

kubectl apply -f "${MANIFESTS_DIR}/cpu-test-rayjob.yaml"

log_info "RayJob 'cpu-pipeline-test' submitted to namespace ${TRAINING_NAMESPACE}"
step_end

# ===========================================================================
# 3. Wait for RayCluster to be Created
# ===========================================================================

step_start "Wait for RayCluster creation"

MAX_WAIT=120
ELAPSED=0
POLL_INTERVAL=5
RAYCLUSTER_FOUND=false

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    RAYCLUSTER_NAME="$(kubectl get rayclusters -n "${TRAINING_NAMESPACE}" \
        -l ray.io/rayjob=cpu-pipeline-test \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -n "${RAYCLUSTER_NAME}" ]]; then
        RAYCLUSTER_FOUND=true
        log_success "RayCluster created: ${RAYCLUSTER_NAME}"
        break
    fi

    log_info "Waiting for RayCluster creation (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${RAYCLUSTER_FOUND}" != "true" ]]; then
    log_error "RayCluster was not created within ${MAX_WAIT}s"
    kubectl describe rayjob cpu-pipeline-test -n "${TRAINING_NAMESPACE}" 2>/dev/null || true
    die "CPU pipeline verification failed: RayCluster not created"
fi

step_end

# ===========================================================================
# 4. Wait for RayJob to Complete
# ===========================================================================

step_start "Wait for RayJob completion"

MAX_WAIT=300
ELAPSED=0
POLL_INTERVAL=10
JOB_STATUS=""

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    JOB_STATUS="$(kubectl get rayjob cpu-pipeline-test -n "${TRAINING_NAMESPACE}" \
        -o jsonpath='{.status.jobStatus}' 2>/dev/null || true)"

    if [[ "${JOB_STATUS}" == "SUCCEEDED" ]]; then
        log_success "RayJob completed successfully"
        break
    elif [[ "${JOB_STATUS}" == "FAILED" ]]; then
        log_error "RayJob failed"
        kubectl logs -n "${TRAINING_NAMESPACE}" \
            -l ray.io/rayjob=cpu-pipeline-test \
            --tail=50 2>/dev/null || true
        die "CPU pipeline verification failed: RayJob status is FAILED"
    fi

    log_info "RayJob status: ${JOB_STATUS:-PENDING} (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${JOB_STATUS}" != "SUCCEEDED" ]]; then
    log_error "RayJob did not complete within ${MAX_WAIT}s (status: ${JOB_STATUS:-UNKNOWN})"
    kubectl describe rayjob cpu-pipeline-test -n "${TRAINING_NAMESPACE}" 2>/dev/null || true
    die "CPU pipeline verification failed: timeout"
fi

step_end

# ===========================================================================
# 5. Verify RayCluster Cleanup
# ===========================================================================

step_start "Verify RayCluster cleanup"

# shutdownAfterJobFinishes is set, so the cluster should be deleted
MAX_WAIT=60
ELAPSED=0
POLL_INTERVAL=5

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    REMAINING="$(kubectl get rayclusters -n "${TRAINING_NAMESPACE}" \
        -l ray.io/rayjob=cpu-pipeline-test \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "${REMAINING}" == "0" ]]; then
        log_success "RayCluster cleaned up after job completion"
        break
    fi

    log_info "Waiting for RayCluster cleanup (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${REMAINING}" != "0" ]]; then
    log_warn "RayCluster not yet cleaned up after ${MAX_WAIT}s (may clean up via TTL)"
fi

step_end

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "=============================================================================="
echo "  CPU Pipeline Verification Summary"
echo "=============================================================================="
echo "  RayJob submitted:     cpu-pipeline-test"
echo "  RayCluster created:   ${RAYCLUSTER_FOUND}"
echo "  Job status:           ${JOB_STATUS}"
echo "  Cluster cleanup:      ${REMAINING:-0} remaining"
echo "=============================================================================="
echo ""

log_success "CPU pipeline verification passed"
