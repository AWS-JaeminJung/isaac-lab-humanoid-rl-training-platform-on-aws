#!/usr/bin/env bash
################################################################################
# install-kuberay.sh
#
# Deploys the KubeRay Operator via Helm chart with:
#   - Operator running on management nodes
#   - Watches all namespaces for Ray CRDs
#   - Leader election enabled for HA
#   - Waits for CRD registration (RayJob, RayCluster, RayService)
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
CONFIG_DIR="$(cd "${PHASE_DIR}/../../.." && pwd)/docs/deployments/config/helm"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"
# shellcheck source=../../../../lib/helm.sh
source "${SCRIPT_DIR}/../../../lib/helm.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

RAY_SYSTEM_NAMESPACE="$(get_tf_output ray_system_namespace)"

log_info "Namespace: ${RAY_SYSTEM_NAMESPACE}"

# ===========================================================================
# 1. Add KubeRay Helm Repository
# ===========================================================================

step_start "Add KubeRay Helm repo"
helm_repo_add "kuberay" "https://ray-project.github.io/kuberay-helm/"
step_end

# ===========================================================================
# 2. Install KubeRay Operator via Helm
# ===========================================================================

step_start "Install KubeRay Operator Helm chart"

VALUES_FILE="${CONFIG_DIR}/kuberay-operator-values.yaml"

helm_install_or_upgrade "kuberay-operator" \
    "kuberay/kuberay-operator" \
    "${RAY_SYSTEM_NAMESPACE}" \
    "${VALUES_FILE}" \
    --version "1.2.0" \
    --set "nodeSelector.node-type=management"

step_end

# ===========================================================================
# 3. Wait for KubeRay Operator to be Ready
# ===========================================================================

step_start "Wait for KubeRay Operator pods"

kubectl rollout status deployment/kuberay-operator \
    -n "${RAY_SYSTEM_NAMESPACE}" \
    --timeout=180s

log_success "KubeRay Operator is ready"
step_end

# ===========================================================================
# 4. Wait for CRD Registration
# ===========================================================================

step_start "Wait for Ray CRD registration"

EXPECTED_CRDS=("rayjobs.ray.io" "rayclusters.ray.io" "rayservices.ray.io")
MAX_WAIT=120
ELAPSED=0
POLL_INTERVAL=5

for crd in "${EXPECTED_CRDS[@]}"; do
    ELAPSED=0
    while ! kubectl get crd "${crd}" &>/dev/null; do
        if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
            die "CRD ${crd} was not registered within ${MAX_WAIT}s"
        fi
        log_info "Waiting for CRD ${crd} (${ELAPSED}s/${MAX_WAIT}s)..."
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done
    log_success "CRD registered: ${crd}"
done

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "KubeRay Operator deployment complete"
log_info "Operator namespace: ${RAY_SYSTEM_NAMESPACE}"
log_info "CRDs registered: ${EXPECTED_CRDS[*]}"
