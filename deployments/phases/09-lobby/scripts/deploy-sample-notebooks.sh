#!/usr/bin/env bash
################################################################################
# deploy-sample-notebooks.sh
#
# Creates a Kubernetes ConfigMap from the sample .ipynb notebook files so they
# can be mounted into user home directories or distributed via JupyterHub
# lifecycle hooks.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
NOTEBOOKS_DIR="${PHASE_DIR}/notebooks"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

JUPYTERHUB_NAMESPACE="$(get_tf_output jupyterhub_namespace)"

log_info "Namespace:      ${JUPYTERHUB_NAMESPACE}"
log_info "Notebooks dir:  ${NOTEBOOKS_DIR}"

# ===========================================================================
# 1. Validate Notebook Files Exist
# ===========================================================================

step_start "Validate notebook files"

NOTEBOOK_FILES=()
for f in "${NOTEBOOKS_DIR}"/*.ipynb; do
    if [[ -f "${f}" ]]; then
        NOTEBOOK_FILES+=("${f}")
        log_info "Found notebook: $(basename "${f}")"
    fi
done

if [[ ${#NOTEBOOK_FILES[@]} -eq 0 ]]; then
    die "No .ipynb files found in ${NOTEBOOKS_DIR}"
fi

log_success "Found ${#NOTEBOOK_FILES[@]} notebook file(s)"
step_end

# ===========================================================================
# 2. Create ConfigMap from Notebook Files
# ===========================================================================

step_start "Create sample-notebooks ConfigMap"

# Build kubectl create configmap command with --from-file for each notebook
CONFIGMAP_ARGS=(
    create configmap sample-notebooks
    --namespace "${JUPYTERHUB_NAMESPACE}"
    --dry-run=client
    -o yaml
)

for notebook in "${NOTEBOOK_FILES[@]}"; do
    CONFIGMAP_ARGS+=(--from-file="$(basename "${notebook}")=${notebook}")
done

# Apply the ConfigMap (create or update via server-side apply)
kubectl "${CONFIGMAP_ARGS[@]}" | kubectl apply -f -

log_success "ConfigMap 'sample-notebooks' created in namespace '${JUPYTERHUB_NAMESPACE}'"
step_end

# ===========================================================================
# 3. Verify ConfigMap
# ===========================================================================

step_start "Verify ConfigMap"

CONFIGMAP_DATA=$(kubectl get configmap sample-notebooks \
    -n "${JUPYTERHUB_NAMESPACE}" \
    -o jsonpath='{.data}' 2>/dev/null || true)

if [[ -n "${CONFIGMAP_DATA}" ]]; then
    KEY_COUNT=$(echo "${CONFIGMAP_DATA}" | jq 'keys | length' 2>/dev/null || echo "0")
    log_success "ConfigMap contains ${KEY_COUNT} notebook(s)"
else
    log_error "ConfigMap 'sample-notebooks' has no data"
fi

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "Sample notebooks deployed"
log_info "ConfigMap: sample-notebooks (namespace: ${JUPYTERHUB_NAMESPACE})"
log_info "Notebooks can be mounted into user pods via singleuser.extraVolumes/extraVolumeMounts"
