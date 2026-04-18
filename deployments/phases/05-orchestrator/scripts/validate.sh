#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 05 deployment:
#   - KubeRay Operator running in ray-system
#   - OSMO Controller running in orchestration (2 pods)
#   - Ray CRDs registered (RayJob, RayCluster, RayService)
#   - OSMO RBAC in place
#   - Network Policies applied
#   - PDBs configured
#   - OSMO API accessible
#   - Ray Dashboard accessible
#   - ResourceQuota applied in training namespace
#   - ExternalSecrets synced
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

ORCHESTRATION_NAMESPACE="$(get_tf_output orchestration_namespace)"
RAY_SYSTEM_NAMESPACE="$(get_tf_output ray_system_namespace)"
TRAINING_NAMESPACE="$(get_tf_output training_namespace)"
OSMO_HOSTNAME="$(get_tf_output osmo_hostname)"
RAY_DASHBOARD_HOSTNAME="$(get_tf_output ray_dashboard_hostname)"

OSMO_URL="https://${OSMO_HOSTNAME}"
RAY_URL="https://${RAY_DASHBOARD_HOSTNAME}"

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
# 1. KubeRay Operator Running
# ===========================================================================

step_start "KubeRay Operator"

check "KubeRay Operator pods exist" \
    kubectl get pods -n "${RAY_SYSTEM_NAMESPACE}" -l app.kubernetes.io/name=kuberay-operator -o name

KUBERAY_READY=$(kubectl get pods -n "${RAY_SYSTEM_NAMESPACE}" \
    -l app.kubernetes.io/name=kuberay-operator \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${KUBERAY_READY}" -ge 1 ]]; then
    log_success "PASS: ${KUBERAY_READY} KubeRay Operator pod(s) Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: KubeRay Operator not Running (found ${KUBERAY_READY})"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 2. OSMO Controller Running (2 replicas)
# ===========================================================================

step_start "OSMO Controller"

check "OSMO Controller pods exist" \
    kubectl get pods -n "${ORCHESTRATION_NAMESPACE}" -l app.kubernetes.io/name=osmo-controller -o name

OSMO_READY=$(kubectl get pods -n "${ORCHESTRATION_NAMESPACE}" \
    -l app.kubernetes.io/name=osmo-controller \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")
EXPECTED_OSMO=2

if [[ "${OSMO_READY}" -ge "${EXPECTED_OSMO}" ]]; then
    log_success "PASS: ${OSMO_READY}/${EXPECTED_OSMO} OSMO Controller pods Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${OSMO_READY}/${EXPECTED_OSMO} OSMO Controller pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 3. Ray CRDs Registered
# ===========================================================================

step_start "Ray CRDs"

check "CRD rayjobs.ray.io registered" \
    kubectl get crd rayjobs.ray.io

check "CRD rayclusters.ray.io registered" \
    kubectl get crd rayclusters.ray.io

check "CRD rayservices.ray.io registered" \
    kubectl get crd rayservices.ray.io

step_end

# ===========================================================================
# 4. OSMO RBAC
# ===========================================================================

step_start "OSMO RBAC"

check "OSMO Controller ServiceAccount exists" \
    kubectl get serviceaccount osmo-controller-sa -n "${ORCHESTRATION_NAMESPACE}"

check "OSMO ClusterRole exists" \
    kubectl get clusterrole osmo-controller-role

check "OSMO ClusterRoleBinding exists" \
    kubectl get clusterrolebinding osmo-controller-binding

check "OSMO SA can create rayjobs" \
    kubectl auth can-i create rayjobs.ray.io \
        --as="system:serviceaccount:${ORCHESTRATION_NAMESPACE}:osmo-controller-sa" \
        -n "${TRAINING_NAMESPACE}"

check "OSMO SA can get pods" \
    kubectl auth can-i get pods \
        --as="system:serviceaccount:${ORCHESTRATION_NAMESPACE}:osmo-controller-sa" \
        -n "${TRAINING_NAMESPACE}"

step_end

# ===========================================================================
# 5. Network Policies
# ===========================================================================

step_start "Network Policies"

check "NetworkPolicy osmo-api-ingress exists" \
    kubectl get networkpolicy osmo-api-ingress -n "${ORCHESTRATION_NAMESPACE}"

check "NetworkPolicy ray-internal-communication exists" \
    kubectl get networkpolicy ray-internal-communication -n "${TRAINING_NAMESPACE}"

check "NetworkPolicy allow-osmo-to-training exists" \
    kubectl get networkpolicy allow-osmo-to-training -n "${TRAINING_NAMESPACE}"

step_end

# ===========================================================================
# 6. PodDisruptionBudgets
# ===========================================================================

step_start "PodDisruptionBudgets"

check "PDB osmo-controller-pdb exists" \
    kubectl get pdb osmo-controller-pdb -n "${ORCHESTRATION_NAMESPACE}"

check "PDB ray-head-pdb exists" \
    kubectl get pdb ray-head-pdb -n "${TRAINING_NAMESPACE}"

check "PDB kuberay-operator-pdb exists" \
    kubectl get pdb kuberay-operator-pdb -n "${RAY_SYSTEM_NAMESPACE}"

step_end

# ===========================================================================
# 7. OSMO API Accessible
# ===========================================================================

step_start "OSMO API accessible"

check "OSMO API health endpoint" \
    curl -sf --max-time 10 "${OSMO_URL}/healthz"

check "OSMO API Ingress exists" \
    kubectl get ingress osmo-api -n "${ORCHESTRATION_NAMESPACE}"

check "DNS resolves ${OSMO_HOSTNAME}" \
    nslookup "${OSMO_HOSTNAME}"

step_end

# ===========================================================================
# 8. Ray Dashboard Accessible
# ===========================================================================

step_start "Ray Dashboard accessible"

check "Ray Dashboard endpoint" \
    curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "${RAY_URL}/"

check "Ray Dashboard Ingress exists" \
    kubectl get ingress ray-dashboard -n "${ORCHESTRATION_NAMESPACE}"

check "DNS resolves ${RAY_DASHBOARD_HOSTNAME}" \
    nslookup "${RAY_DASHBOARD_HOSTNAME}"

step_end

# ===========================================================================
# 9. ResourceQuota in Training Namespace
# ===========================================================================

step_start "ResourceQuota"

check "ResourceQuota training-gpu-quota exists" \
    kubectl get resourcequota training-gpu-quota -n "${TRAINING_NAMESPACE}"

GPU_LIMIT=$(kubectl get resourcequota training-gpu-quota -n "${TRAINING_NAMESPACE}" \
    -o jsonpath='{.spec.hard.limits\.nvidia\.com/gpu}' 2>/dev/null || echo "0")

if [[ "${GPU_LIMIT}" == "80" ]]; then
    log_success "PASS: GPU quota limit is ${GPU_LIMIT}"
    PASS=$((PASS + 1))
else
    log_error "FAIL: GPU quota limit is ${GPU_LIMIT}, expected 80"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 10. ExternalSecrets Synced
# ===========================================================================

step_start "ExternalSecrets"

check "ExternalSecret osmo-db-credentials synced" \
    kubectl get externalsecret osmo-db-credentials -n "${ORCHESTRATION_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"

check "ExternalSecret osmo-oidc-credentials synced" \
    kubectl get externalsecret osmo-oidc-credentials -n "${ORCHESTRATION_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 05 Validation Summary"
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
