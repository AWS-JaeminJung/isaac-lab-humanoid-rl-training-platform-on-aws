#!/usr/bin/env bash
################################################################################
# run-multi-node.sh
#
# Stage 3: Multi-Node validation (2 nodes, 16 GPUs)
#   - Applies stage3-rayjob.yaml (envsubst for ECR_REPO_URL)
#   - Waits for 2 GPU nodes to be provisioned by Karpenter
#   - Waits for RayJob completion
#   - Checks EFA/NCCL communication (from pod logs)
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
RAYJOB_NAME="h1-multi-node-validation"
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

step_start "Clean up previous Stage 3 runs"

kubectl delete rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

log_info "Previous Stage 3 runs cleaned up"
step_end

# ===========================================================================
# 2. Apply Stage 3 RayJob Manifest
# ===========================================================================

step_start "Submit Stage 3 RayJob (multi-node, 2x 8 GPU)"

envsubst < "${MANIFESTS_DIR}/stage3-rayjob.yaml" | kubectl apply -f -

log_info "RayJob '${RAYJOB_NAME}' submitted to namespace ${TRAINING_NAMESPACE}"
step_end

# ===========================================================================
# 3. Wait for Karpenter to Provision 2 GPU Nodes
# ===========================================================================

step_start "Wait for Karpenter to provision GPU nodes"

MAX_WAIT=600
ELAPSED=0
POLL_INTERVAL=15
REQUIRED_NODES=2

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    GPU_NODES="$(kubectl get nodes -l node-type=gpu --no-headers 2>/dev/null | grep -c "Ready" || echo "0")"

    if [[ "${GPU_NODES}" -ge "${REQUIRED_NODES}" ]]; then
        log_success "${GPU_NODES} GPU node(s) ready (required: ${REQUIRED_NODES})"
        break
    fi

    log_info "GPU nodes ready: ${GPU_NODES}/${REQUIRED_NODES} (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${GPU_NODES}" -lt "${REQUIRED_NODES}" ]]; then
    log_error "Only ${GPU_NODES}/${REQUIRED_NODES} GPU nodes provisioned within ${MAX_WAIT}s"
    kubectl get nodeclaims -A 2>/dev/null || true
    die "Stage 3 failed: insufficient GPU nodes"
fi

check "Karpenter provisioned ${REQUIRED_NODES} GPU nodes" \
    test "${GPU_NODES}" -ge "${REQUIRED_NODES}"

step_end

# ===========================================================================
# 4. Wait for RayJob Completion
# ===========================================================================

step_start "Wait for RayJob completion"

MAX_WAIT=2400
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
            --tail=100 2>/dev/null || true
        die "Stage 3 failed: RayJob status is FAILED"
    fi

    log_info "RayJob status: ${JOB_STATUS:-PENDING} (${ELAPSED}s/${MAX_WAIT}s)..."
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${JOB_STATUS}" != "SUCCEEDED" ]]; then
    log_error "RayJob did not complete within ${MAX_WAIT}s (status: ${JOB_STATUS:-UNKNOWN})"
    kubectl describe rayjob "${RAYJOB_NAME}" -n "${TRAINING_NAMESPACE}" 2>/dev/null || true
    die "Stage 3 failed: timeout"
fi

step_end

# ===========================================================================
# 5. Check EFA/NCCL Communication
# ===========================================================================

step_start "Verify EFA/NCCL communication"

# Retrieve worker pod logs and check for NCCL initialization messages
WORKER_PODS="$(kubectl get pods -n "${TRAINING_NAMESPACE}" \
    -l ray.io/rayjob="${RAYJOB_NAME}",ray.io/node-type=worker \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

NCCL_VERIFIED=false
for POD in ${WORKER_PODS}; do
    NCCL_OUTPUT="$(kubectl logs -n "${TRAINING_NAMESPACE}" "${POD}" --tail=500 2>/dev/null || true)"

    if echo "${NCCL_OUTPUT}" | grep -q "NCCL INFO"; then
        log_info "NCCL initialization detected in pod ${POD}"
        NCCL_VERIFIED=true
    fi

    if echo "${NCCL_OUTPUT}" | grep -q "NET/OFI"; then
        log_info "EFA (OFI) transport detected in pod ${POD}"
    fi
done

check "NCCL communication initialized across nodes" \
    test "${NCCL_VERIFIED}" == "true"

check "ClickHouse has metrics for Stage 3 workflow" \
    bash -c "kubectl exec -n '${LOGGING_NAMESPACE}' clickhouse-0 -- \
        clickhouse-client --query \"SELECT count() FROM training_metrics WHERE workflow_id LIKE '%multi-node%'\" \
        | grep -v '^0$'"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Stage 3: Multi-Node Validation Summary"
echo "=============================================================================="
echo "  RayJob:       ${RAYJOB_NAME}"
echo "  Nodes:        2 (16 GPUs total)"
echo "  Status:       ${JOB_STATUS}"
echo "  NCCL:         ${NCCL_VERIFIED}"
echo "  GPU Nodes:    ${GPU_NODES}"
echo "  Checks:       PASSED=${PASS}/${TOTAL}  FAILED=${FAIL}/${TOTAL}"
echo "=============================================================================="
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    log_error "Stage 3 completed with ${FAIL} failure(s)"
    exit 1
else
    log_success "Stage 3: Multi-Node validation passed"
    exit 0
fi
