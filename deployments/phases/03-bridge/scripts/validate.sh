#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 03 deployment:
#   - Hybrid nodes visible in kubectl get nodes
#   - nvidia.com/gpu resource advertised on nodes
#   - Labels and taints correctly applied
#   - S3 connectivity from hybrid nodes
#   - ECR connectivity
#   - Sample GPU test job runs successfully
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

CLUSTER_NAME="$(get_tf_output cluster_name)"
AWS_REGION="${AWS_REGION:-us-east-1}"

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
# 1. Hybrid Nodes Visible
# ===========================================================================

step_start "Hybrid nodes visible in cluster"

check "kubectl cluster-info" kubectl cluster-info

# Check for nodes with on-prem label
ONPREM_NODES=$(kubectl get nodes -l node-type=onprem-gpu --no-headers 2>/dev/null || true)
ONPREM_COUNT=$(echo "${ONPREM_NODES}" | grep -c '.' 2>/dev/null || echo "0")

if [[ "${ONPREM_COUNT}" -gt 0 ]]; then
    log_success "PASS: ${ONPREM_COUNT} on-prem hybrid node(s) found"
    PASS=$((PASS + 1))
else
    log_error "FAIL: No on-prem hybrid nodes found (label node-type=onprem-gpu)"
    FAIL=$((FAIL + 1))
fi

# Check nodes are Ready
if [[ "${ONPREM_COUNT}" -gt 0 ]]; then
    READY_COUNT=$(echo "${ONPREM_NODES}" | grep -c " Ready " || echo "0")
    if [[ "${READY_COUNT}" -ge "${ONPREM_COUNT}" ]]; then
        log_success "PASS: All ${READY_COUNT} on-prem nodes in Ready state"
        PASS=$((PASS + 1))
    else
        log_error "FAIL: Only ${READY_COUNT}/${ONPREM_COUNT} on-prem nodes in Ready state"
        FAIL=$((FAIL + 1))
    fi
fi

step_end

# ===========================================================================
# 2. GPU Resources Advertised
# ===========================================================================

step_start "nvidia.com/gpu resource on nodes"

if [[ "${ONPREM_COUNT}" -gt 0 ]]; then
    GPU_NODES=$(kubectl get nodes -l node-type=onprem-gpu \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)

    GPU_TOTAL=0
    while IFS=$'\t' read -r node_name gpu_count; do
        if [[ -n "${gpu_count}" ]] && [[ "${gpu_count}" -gt 0 ]]; then
            log_success "PASS: Node ${node_name} reports ${gpu_count} GPU(s)"
            PASS=$((PASS + 1))
            GPU_TOTAL=$((GPU_TOTAL + gpu_count))
        else
            log_error "FAIL: Node ${node_name} reports no nvidia.com/gpu resource"
            FAIL=$((FAIL + 1))
        fi
    done <<< "${GPU_NODES}"

    log_info "Total GPU capacity across on-prem nodes: ${GPU_TOTAL}"
else
    log_warn "SKIP: No on-prem nodes to check GPU resources"
fi

step_end

# ===========================================================================
# 3. Labels and Taints
# ===========================================================================

step_start "Labels and taints on hybrid nodes"

if [[ "${ONPREM_COUNT}" -gt 0 ]]; then
    NODE_NAMES=$(kubectl get nodes -l node-type=onprem-gpu \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null)

    echo "${NODE_NAMES}" | while read -r node; do
        [[ -z "${node}" ]] && continue

        # Check gpu-model label
        GPU_MODEL=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.gpu-model}' 2>/dev/null || true)
        if [[ "${GPU_MODEL}" == "rtx-pro-6000" ]]; then
            log_success "PASS: Node ${node} has label gpu-model=rtx-pro-6000"
        else
            log_error "FAIL: Node ${node} missing label gpu-model=rtx-pro-6000 (got: ${GPU_MODEL:-<none>})"
        fi

        # Check taint
        TAINT_FOUND=$(kubectl get node "${node}" \
            -o jsonpath='{.spec.taints[?(@.key=="workload-type")].effect}' 2>/dev/null || true)
        if [[ "${TAINT_FOUND}" == "NoSchedule" ]]; then
            log_success "PASS: Node ${node} has taint workload-type=onprem-single-gpu:NoSchedule"
        else
            log_error "FAIL: Node ${node} missing taint workload-type:NoSchedule (got: ${TAINT_FOUND:-<none>})"
        fi
    done
else
    log_warn "SKIP: No on-prem nodes to check labels/taints"
fi

step_end

# ===========================================================================
# 4. NVIDIA Device Plugin Running
# ===========================================================================

step_start "NVIDIA Device Plugin DaemonSet"

check "Device plugin DaemonSet exists" \
    kubectl get daemonset nvidia-device-plugin-onprem -n kube-system

DESIRED=$(kubectl get daemonset nvidia-device-plugin-onprem -n kube-system \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
READY=$(kubectl get daemonset nvidia-device-plugin-onprem -n kube-system \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [[ "${DESIRED}" -gt 0 ]] && [[ "${READY}" -ge "${DESIRED}" ]]; then
    log_success "PASS: Device plugin DaemonSet ${READY}/${DESIRED} pods ready"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Device plugin DaemonSet ${READY}/${DESIRED} pods ready"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 5. S3 Connectivity
# ===========================================================================

step_start "S3 connectivity"

S3_CHECKPOINTS=$(get_tf_output s3_checkpoints_bucket 2>/dev/null || \
    terraform -chdir="${PHASE_DIR}/../02-platform/terraform" output -raw s3_checkpoints_bucket 2>/dev/null || true)
S3_TRAINING_DATA=$(get_tf_output s3_training_data_bucket 2>/dev/null || \
    terraform -chdir="${PHASE_DIR}/../02-platform/terraform" output -raw s3_training_data_bucket 2>/dev/null || true)

if [[ -n "${S3_CHECKPOINTS}" ]]; then
    check "S3 checkpoints bucket '${S3_CHECKPOINTS}' accessible" \
        aws s3api head-bucket --bucket "${S3_CHECKPOINTS}" --region "${AWS_REGION}"
else
    log_warn "SKIP: Could not determine S3 checkpoints bucket name"
fi

if [[ -n "${S3_TRAINING_DATA}" ]]; then
    check "S3 training data bucket '${S3_TRAINING_DATA}' accessible" \
        aws s3api head-bucket --bucket "${S3_TRAINING_DATA}" --region "${AWS_REGION}"
else
    log_warn "SKIP: Could not determine S3 training data bucket name"
fi

step_end

# ===========================================================================
# 6. ECR Connectivity
# ===========================================================================

step_start "ECR connectivity"

check "ECR login succeeds" \
    aws ecr get-login-password --region "${AWS_REGION}"

ECR_REPO_NAME="isaac-lab-training"
check "ECR repository '${ECR_REPO_NAME}' exists" \
    aws ecr describe-repositories \
        --repository-names "${ECR_REPO_NAME}" \
        --region "${AWS_REGION}"

step_end

# ===========================================================================
# 7. GPU Test Job
# ===========================================================================

step_start "GPU test job (nvidia-smi)"

GPU_TEST_MANIFEST="${MANIFESTS_DIR}/onprem-gpu-test-job.yaml"

if [[ -f "${GPU_TEST_MANIFEST}" ]] && [[ "${ONPREM_COUNT}" -gt 0 ]]; then
    TEST_JOB_NAME="gpu-test-$(date +%s)"

    # Apply the test job with a unique name
    sed "s/name: onprem-gpu-test/name: ${TEST_JOB_NAME}/" "${GPU_TEST_MANIFEST}" | \
        kubectl apply -f -

    log_info "Waiting for test job '${TEST_JOB_NAME}' to complete (timeout: 120s)..."

    if kubectl wait --for=condition=complete "job/${TEST_JOB_NAME}" \
        --namespace default --timeout=120s 2>/dev/null; then
        log_success "PASS: GPU test job completed successfully"
        PASS=$((PASS + 1))

        # Show nvidia-smi output
        POD_NAME=$(kubectl get pods --selector="job-name=${TEST_JOB_NAME}" \
            --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)
        if [[ -n "${POD_NAME}" ]]; then
            log_info "nvidia-smi output:"
            kubectl logs "${POD_NAME}" 2>/dev/null || true
        fi
    else
        log_error "FAIL: GPU test job did not complete within 120s"
        FAIL=$((FAIL + 1))

        # Show pod status for debugging
        kubectl describe "job/${TEST_JOB_NAME}" 2>/dev/null || true
    fi

    # Clean up test job
    kubectl delete "job/${TEST_JOB_NAME}" --ignore-not-found=true 2>/dev/null || true
else
    if [[ ! -f "${GPU_TEST_MANIFEST}" ]]; then
        log_warn "SKIP: GPU test manifest not found: ${GPU_TEST_MANIFEST}"
    else
        log_warn "SKIP: No on-prem GPU nodes available for test job"
    fi
fi

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 03 Validation Summary"
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
