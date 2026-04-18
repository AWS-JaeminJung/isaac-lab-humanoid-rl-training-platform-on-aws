#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 02 deployment:
#   - EKS cluster reachable
#   - Management nodes Ready
#   - EBS CSI driver running
#   - FSx CSI driver running
#   - Karpenter running
#   - S3 buckets accessible
#   - ECR accessible
#   - RDS connectable
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

CLUSTER_NAME="$(get_tf_output cluster_name)"
RDS_ENDPOINT="$(get_tf_output rds_endpoint)"
RDS_PORT="$(get_tf_output rds_port)"
S3_CHECKPOINTS="$(get_tf_output s3_checkpoints_bucket)"
S3_MODELS="$(get_tf_output s3_models_bucket)"
S3_LOGS_ARCHIVE="$(get_tf_output s3_logs_archive_bucket)"
S3_TRAINING_DATA="$(get_tf_output s3_training_data_bucket)"
ECR_URL="$(get_tf_output ecr_repository_url)"
AWS_REGION="${AWS_REGION:-$(get_tf_output aws_region 2>/dev/null || echo "us-east-1")}"

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
# 1. EKS Cluster Reachable
# ===========================================================================

step_start "EKS cluster reachable"
check "kubectl cluster-info" kubectl cluster-info
check "kubectl get namespaces" kubectl get namespaces
step_end

# ===========================================================================
# 2. Management Nodes Ready
# ===========================================================================

step_start "Management nodes Ready"
check "Management nodes exist" kubectl get nodes -l node-type=management -o name

# Verify all management nodes are Ready
READY_NODES=$(kubectl get nodes -l node-type=management --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
EXPECTED_NODES=3
if [[ "${READY_NODES}" -ge "${EXPECTED_NODES}" ]]; then
    log_success "PASS: ${READY_NODES}/${EXPECTED_NODES} management nodes Ready"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${READY_NODES}/${EXPECTED_NODES} management nodes Ready"
    FAIL=$((FAIL + 1))
fi
step_end

# ===========================================================================
# 3. EBS CSI Driver Running
# ===========================================================================

step_start "EBS CSI driver"
check "EBS CSI addon active" \
    aws eks describe-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name aws-ebs-csi-driver \
        --region "${AWS_REGION}" \
        --query 'addon.status' \
        --output text

check "EBS CSI controller pods" \
    kubectl get pods -n kube-system -l app=ebs-csi-controller -o name

check "gp3 StorageClass exists" \
    kubectl get storageclass gp3
step_end

# ===========================================================================
# 4. FSx CSI Driver Running
# ===========================================================================

step_start "FSx CSI driver"
check "FSx CSI controller pods" \
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-fsx-csi-driver -o name
step_end

# ===========================================================================
# 5. Karpenter Running
# ===========================================================================

step_start "Karpenter"
check "Karpenter pods running" \
    kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o name

check "NodePool gpu-pool exists" \
    kubectl get nodepool gpu-pool

check "EC2NodeClass gpu-class exists" \
    kubectl get ec2nodeclass gpu-class
step_end

# ===========================================================================
# 6. S3 Buckets Accessible
# ===========================================================================

step_start "S3 buckets"
for bucket in "${S3_CHECKPOINTS}" "${S3_MODELS}" "${S3_LOGS_ARCHIVE}" "${S3_TRAINING_DATA}"; do
    check "S3 bucket '${bucket}' accessible" \
        aws s3api head-bucket --bucket "${bucket}" --region "${AWS_REGION}"
done
step_end

# ===========================================================================
# 7. ECR Accessible
# ===========================================================================

step_start "ECR repository"
ECR_REPO_NAME="isaac-lab-training"
check "ECR repository '${ECR_REPO_NAME}' exists" \
    aws ecr describe-repositories \
        --repository-names "${ECR_REPO_NAME}" \
        --region "${AWS_REGION}"
step_end

# ===========================================================================
# 8. RDS Connectable
# ===========================================================================

step_start "RDS PostgreSQL"
check "RDS instance available" \
    aws rds describe-db-instances \
        --db-instance-identifier "${CLUSTER_NAME}-postgres" \
        --region "${AWS_REGION}" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text

log_info "RDS endpoint: ${RDS_ENDPOINT}:${RDS_PORT}"

# Network-level connectivity test (if nc/ncat is available)
if command -v nc &>/dev/null; then
    check "RDS port ${RDS_PORT} reachable" \
        nc -z -w5 "${RDS_ENDPOINT}" "${RDS_PORT}"
else
    log_warn "SKIP: nc not available for RDS port test"
fi
step_end

# ===========================================================================
# 9. External Secrets Operator
# ===========================================================================

step_start "External Secrets Operator"
check "External Secrets pods running" \
    kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets -o name

check "ClusterSecretStore exists" \
    kubectl get clustersecretstore aws-secrets-manager
step_end

# ===========================================================================
# 10. AWS Load Balancer Controller
# ===========================================================================

step_start "AWS Load Balancer Controller"
check "ALB Controller pods running" \
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name
step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 02 Validation Summary"
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
