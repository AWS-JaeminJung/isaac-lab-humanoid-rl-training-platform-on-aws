#!/usr/bin/env bash
################################################################################
# install-clickhouse.sh
#
# Deploys ClickHouse as a Kubernetes StatefulSet + Service:
#   - Applies clickhouse-statefulset.yaml and clickhouse-service.yaml
#   - Waits for the StatefulSet to become ready
#   - Verifies HTTP API accessible on port 8123
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
MANIFESTS_DIR="${PHASE_DIR}/manifests"

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

LOGGING_NAMESPACE="$(get_tf_output logging_namespace)"

log_info "Namespace: ${LOGGING_NAMESPACE}"

# ===========================================================================
# 1. Apply ClickHouse StatefulSet Manifest
# ===========================================================================

step_start "Apply ClickHouse StatefulSet"

kubectl apply -f "${MANIFESTS_DIR}/clickhouse-statefulset.yaml"

log_info "ClickHouse StatefulSet manifest applied"
step_end

# ===========================================================================
# 2. Apply ClickHouse Service Manifest
# ===========================================================================

step_start "Apply ClickHouse Service"

kubectl apply -f "${MANIFESTS_DIR}/clickhouse-service.yaml"

log_info "ClickHouse Service manifest applied"
step_end

# ===========================================================================
# 3. Wait for StatefulSet Ready
# ===========================================================================

step_start "Wait for ClickHouse StatefulSet to be ready"

MAX_WAIT=300
log_info "Waiting up to ${MAX_WAIT}s for clickhouse statefulset to become ready..."

if kubectl rollout status statefulset/clickhouse \
    -n "${LOGGING_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "ClickHouse StatefulSet is ready"
else
    die "ClickHouse StatefulSet did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# 4. Verify HTTP API Accessible
# ===========================================================================

step_start "Verify ClickHouse HTTP API"

CH_LOCAL_PORT=18123
kubectl port-forward svc/clickhouse \
    -n "${LOGGING_NAMESPACE}" \
    "${CH_LOCAL_PORT}:8123" &
PF_PID=$!

cleanup_pf() {
    if kill -0 "${PF_PID}" 2>/dev/null; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    fi
}
trap cleanup_pf EXIT

sleep 3

if curl -sf --max-time 10 "http://localhost:${CH_LOCAL_PORT}/ping" | grep -q "Ok"; then
    log_success "ClickHouse HTTP API is responding"
else
    die "ClickHouse HTTP API is not responding on port 8123"
fi

# Clean up port-forward
cleanup_pf
trap - EXIT

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "ClickHouse deployment complete"
log_info "ClickHouse is available at http://clickhouse.${LOGGING_NAMESPACE}.svc.cluster.local:8123"
