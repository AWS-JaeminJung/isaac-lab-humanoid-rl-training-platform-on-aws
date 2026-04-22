#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 09 deployment:
#   - JupyterHub Hub pod running
#   - JupyterHub Proxy pod running
#   - HTTPS URL accessible
#   - OIDC redirect works (302 to Keycloak)
#   - ECR notebook image accessible
#   - Ingress / DNS resolution
#   - ExternalSecret synced
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

JUPYTERHUB_NAMESPACE="$(get_tf_output jupyterhub_namespace)"
JUPYTERHUB_HOSTNAME="$(get_tf_output jupyterhub_hostname)"
JUPYTERHUB_URL="https://${JUPYTERHUB_HOSTNAME}"
ECR_REPO_URL="$(get_tf_output ecr_repository_url)"
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
# 1. JupyterHub Hub Pod Running
# ===========================================================================

step_start "JupyterHub Hub pod"

check "Hub Deployment exists" \
    kubectl get deployment hub -n "${JUPYTERHUB_NAMESPACE}"

HUB_READY=$(kubectl get pods -n "${JUPYTERHUB_NAMESPACE}" \
    -l app=jupyterhub,component=hub \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${HUB_READY}" -ge 1 ]]; then
    log_success "PASS: ${HUB_READY} Hub pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: No Hub pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 2. JupyterHub Proxy Pod Running
# ===========================================================================

step_start "JupyterHub Proxy pod"

check "Proxy Deployment exists" \
    kubectl get deployment proxy -n "${JUPYTERHUB_NAMESPACE}"

PROXY_READY=$(kubectl get pods -n "${JUPYTERHUB_NAMESPACE}" \
    -l app=jupyterhub,component=proxy \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${PROXY_READY}" -ge 1 ]]; then
    log_success "PASS: ${PROXY_READY} Proxy pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: No Proxy pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 3. HTTPS URL Accessible
# ===========================================================================

step_start "HTTPS URL accessible"

HTTP_CODE=$(curl -sf --max-time 15 -o /dev/null -w '%{http_code}' \
    "${JUPYTERHUB_URL}/" 2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" || "${HTTP_CODE}" == "301" ]]; then
    log_success "PASS: JupyterHub URL returns HTTP ${HTTP_CODE}"
    PASS=$((PASS + 1))
else
    log_error "FAIL: JupyterHub URL returned HTTP ${HTTP_CODE} (expected 200/301/302)"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 4. OIDC Redirect to Keycloak
# ===========================================================================

step_start "OIDC redirect to Keycloak"

REDIRECT_URL=$(curl -sf --max-time 15 -o /dev/null -w '%{redirect_url}' \
    "${JUPYTERHUB_URL}/hub/login" 2>/dev/null || echo "")

if echo "${REDIRECT_URL}" | grep -qi "keycloak"; then
    log_success "PASS: Login redirects to Keycloak (${REDIRECT_URL})"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Login does not redirect to Keycloak (redirect: ${REDIRECT_URL:-none})"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 5. ECR Notebook Image Accessible
# ===========================================================================

step_start "ECR notebook image"

IMAGE_NAME="jupyterhub-notebook"
IMAGE_TAG="v1.0.0"

ECR_IMAGE_EXISTS=$(aws ecr describe-images \
    --repository-name "${IMAGE_NAME}" \
    --image-ids imageTag="${IMAGE_TAG}" \
    --region "${AWS_REGION}" \
    --query 'imageDetails[0].imageTags' \
    --output text 2>/dev/null || true)

if [[ -n "${ECR_IMAGE_EXISTS}" && "${ECR_IMAGE_EXISTS}" != "None" ]]; then
    log_success "PASS: ECR image exists: ${IMAGE_NAME}:${IMAGE_TAG}"
    PASS=$((PASS + 1))
else
    log_error "FAIL: ECR image not found: ${IMAGE_NAME}:${IMAGE_TAG}"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 6. Ingress and DNS Resolution
# ===========================================================================

step_start "Ingress and DNS"

check "JupyterHub Ingress exists" \
    kubectl get ingress jupyterhub -n "${JUPYTERHUB_NAMESPACE}"

check "Ingress has ALB address" \
    kubectl get ingress jupyterhub -n "${JUPYTERHUB_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

check "DNS resolves ${JUPYTERHUB_HOSTNAME}" \
    nslookup "${JUPYTERHUB_HOSTNAME}"

step_end

# ===========================================================================
# 7. ExternalSecret Synced
# ===========================================================================

step_start "ExternalSecret synced"

ES_STATUS=$(kubectl get externalsecret jupyterhub-oidc-credentials \
    -n "${JUPYTERHUB_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

if [[ "${ES_STATUS}" == "True" ]]; then
    log_success "PASS: ExternalSecret jupyterhub-oidc-credentials is synced"
    PASS=$((PASS + 1))
else
    log_error "FAIL: ExternalSecret jupyterhub-oidc-credentials not synced (status: ${ES_STATUS:-unknown})"
    FAIL=$((FAIL + 1))
fi

# Verify the K8s secret exists and has data
check "K8s secret jupyterhub-oidc-credentials exists" \
    kubectl get secret jupyterhub-oidc-credentials -n "${JUPYTERHUB_NAMESPACE}"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 09 Validation Summary"
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
