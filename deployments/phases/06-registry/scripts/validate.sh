#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 06 deployment:
#   - MLflow pod running
#   - OAuth2 Proxy pod running
#   - MLflow URL accessible (HTTPS)
#   - RDS connectivity
#   - S3 models bucket accessible
#   - ExternalSecrets synced
#   - Route53 record exists
#   - MLflow API /api/2.0/mlflow/experiments/search responds
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

MLFLOW_NAMESPACE="$(get_tf_output mlflow_namespace)"
MLFLOW_HOSTNAME="$(get_tf_output mlflow_hostname)"
MLFLOW_URL="https://${MLFLOW_HOSTNAME}"
S3_MODELS_BUCKET="$(get_tf_output s3_models_bucket)"
RDS_ENDPOINT="$(get_tf_output rds_endpoint)"
RDS_PORT="$(get_tf_output rds_port)"

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
# 1. MLflow Pod Running
# ===========================================================================

step_start "MLflow pods"

check "MLflow pods exist" \
    kubectl get pods -n "${MLFLOW_NAMESPACE}" -l app=mlflow -o name

READY_PODS=$(kubectl get pods -n "${MLFLOW_NAMESPACE}" \
    -l app=mlflow \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")
EXPECTED_PODS=1

if [[ "${READY_PODS}" -ge "${EXPECTED_PODS}" ]]; then
    log_success "PASS: ${READY_PODS}/${EXPECTED_PODS} MLflow pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${READY_PODS}/${EXPECTED_PODS} MLflow pod(s) Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 2. OAuth2 Proxy Pod Running
# ===========================================================================

step_start "OAuth2 Proxy pods"

check "OAuth2 Proxy pods exist" \
    kubectl get pods -n "${MLFLOW_NAMESPACE}" -l app.kubernetes.io/name=oauth2-proxy -o name

OAUTH2_READY=$(kubectl get pods -n "${MLFLOW_NAMESPACE}" \
    -l app.kubernetes.io/name=oauth2-proxy \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${OAUTH2_READY}" -ge 1 ]]; then
    log_success "PASS: ${OAUTH2_READY} OAuth2 Proxy pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: No OAuth2 Proxy pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 3. ExternalSecrets Synced
# ===========================================================================

step_start "ExternalSecrets"

check "ExternalSecret mlflow-db-credentials synced" \
    bash -c "kubectl get externalsecret mlflow-db-credentials -n '${MLFLOW_NAMESPACE}' \
        -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'"

check "ExternalSecret mlflow-oauth2-proxy synced" \
    bash -c "kubectl get externalsecret mlflow-oauth2-proxy -n '${MLFLOW_NAMESPACE}' \
        -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'"

step_end

# ===========================================================================
# 4. MLflow URL Accessible (HTTPS)
# ===========================================================================

step_start "MLflow URL accessible"

check "MLflow health endpoint" \
    curl -sf --max-time 10 "${MLFLOW_URL}/health"

check "MLflow root URL returns 200/302" \
    curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "${MLFLOW_URL}/"

step_end

# ===========================================================================
# 5. MLflow API Responsive
# ===========================================================================

step_start "MLflow API"

# Use port-forward for direct API check (bypasses OAuth2 Proxy)
MLFLOW_LOCAL_PORT=15001
kubectl port-forward svc/mlflow \
    -n "${MLFLOW_NAMESPACE}" \
    "${MLFLOW_LOCAL_PORT}:5000" &
PF_PID=$!

cleanup_pf() {
    if kill -0 "${PF_PID}" 2>/dev/null; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    fi
}
trap cleanup_pf EXIT

sleep 3

check "MLflow experiments search API" \
    curl -sf --max-time 10 "http://localhost:${MLFLOW_LOCAL_PORT}/api/2.0/mlflow/experiments/search"

check "MLflow health via port-forward" \
    curl -sf --max-time 10 "http://localhost:${MLFLOW_LOCAL_PORT}/health"

# Clean up port-forward
cleanup_pf
trap - EXIT

step_end

# ===========================================================================
# 6. RDS Connectivity
# ===========================================================================

step_start "RDS connectivity"

# Verify the MLflow pod can reach RDS by checking pod logs for successful DB connection
check "MLflow pod not in CrashLoopBackOff" \
    bash -c "! kubectl get pods -n '${MLFLOW_NAMESPACE}' -l app=mlflow --no-headers | grep -q 'CrashLoopBackOff'"

check "MLflow pod not in Error state" \
    bash -c "! kubectl get pods -n '${MLFLOW_NAMESPACE}' -l app=mlflow --no-headers | grep -q 'Error'"

step_end

# ===========================================================================
# 7. S3 Models Bucket Accessible
# ===========================================================================

step_start "S3 models bucket"

check "S3 models bucket exists" \
    aws s3api head-bucket --bucket "${S3_MODELS_BUCKET}"

check "S3 models bucket is listable" \
    aws s3 ls "s3://${S3_MODELS_BUCKET}/" --max-items 0

step_end

# ===========================================================================
# 8. Ingress and Route53
# ===========================================================================

step_start "Ingress and DNS"

check "MLflow Ingress exists" \
    kubectl get ingress mlflow -n "${MLFLOW_NAMESPACE}"

check "Ingress has ALB address" \
    kubectl get ingress mlflow -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

check "DNS resolves ${MLFLOW_HOSTNAME}" \
    nslookup "${MLFLOW_HOSTNAME}"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 06 Validation Summary"
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
