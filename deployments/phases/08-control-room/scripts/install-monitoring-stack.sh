#!/usr/bin/env bash
################################################################################
# install-monitoring-stack.sh
#
# Deploys the kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# via Helm chart:
#   - Adds prometheus-community Helm repo
#   - Installs kube-prometheus-stack in the monitoring namespace
#   - Uses config/helm/kube-prometheus-stack-values.yaml
#   - Configures Grafana with Keycloak OIDC auth
#   - Waits for all pods to become ready
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
CONFIG_DIR="$(cd "${PHASE_DIR}/../../../config/helm" && pwd)"

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

MONITORING_NAMESPACE="$(get_tf_output monitoring_namespace)"
GRAFANA_HOSTNAME="$(get_tf_output grafana_hostname)"

log_info "Namespace:         ${MONITORING_NAMESPACE}"
log_info "Grafana Hostname:  ${GRAFANA_HOSTNAME}"

# ===========================================================================
# 1. Add Prometheus Community Helm Repository
# ===========================================================================

step_start "Add prometheus-community Helm repo"
helm_repo_add "prometheus-community" "https://prometheus-community.github.io/helm-charts"
step_end

# ===========================================================================
# 2. Retrieve Grafana Admin Password from ExternalSecret
# ===========================================================================

step_start "Retrieve Grafana admin password"

MAX_RETRIES=12
RETRY_INTERVAL=10
RETRY_COUNT=0

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    GRAFANA_ADMIN_PASSWORD="$(kubectl get secret grafana-admin-credentials \
        -n "${MONITORING_NAMESPACE}" \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"

    if [[ -n "${GRAFANA_ADMIN_PASSWORD}" && "${GRAFANA_ADMIN_PASSWORD}" != "CHANGE_ME_BEFORE_DEPLOY" ]]; then
        log_success "Grafana admin password retrieved from ExternalSecret"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
        die "Grafana admin password not available. Ensure the secret is populated in Secrets Manager."
    fi

    log_info "Waiting for grafana-admin-credentials secret (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep "${RETRY_INTERVAL}"
done

step_end

# ===========================================================================
# 3. Install kube-prometheus-stack via Helm
# ===========================================================================

step_start "Install kube-prometheus-stack Helm chart"

VALUES_FILE="${CONFIG_DIR}/kube-prometheus-stack-values.yaml"

if [[ ! -f "${VALUES_FILE}" ]]; then
    die "Helm values file not found: ${VALUES_FILE}"
fi

helm_install_or_upgrade "kube-prometheus-stack" \
    "prometheus-community/kube-prometheus-stack" \
    "${MONITORING_NAMESPACE}" \
    "${VALUES_FILE}" \
    --version "65.1.0" \
    --set "grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD}" \
    --set "grafana.grafana\\.ini.server.root_url=https://${GRAFANA_HOSTNAME}" \
    --timeout 10m

step_end

# ===========================================================================
# 4. Wait for Prometheus to be Ready
# ===========================================================================

step_start "Wait for Prometheus pods"

MAX_WAIT=300
log_info "Waiting up to ${MAX_WAIT}s for Prometheus StatefulSet..."

if kubectl rollout status statefulset/prometheus-kube-prometheus-stack-prometheus \
    -n "${MONITORING_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "Prometheus is ready"
else
    die "Prometheus did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# 5. Wait for Grafana to be Ready
# ===========================================================================

step_start "Wait for Grafana pods"

MAX_WAIT=300
log_info "Waiting up to ${MAX_WAIT}s for Grafana Deployment..."

if kubectl rollout status deployment/kube-prometheus-stack-grafana \
    -n "${MONITORING_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "Grafana is ready"
else
    die "Grafana did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# 6. Wait for Alertmanager to be Ready
# ===========================================================================

step_start "Wait for Alertmanager pods"

MAX_WAIT=180
log_info "Waiting up to ${MAX_WAIT}s for Alertmanager StatefulSet..."

if kubectl rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager \
    -n "${MONITORING_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "Alertmanager is ready"
else
    die "Alertmanager did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "kube-prometheus-stack deployment complete"
log_info "Prometheus: prometheus-kube-prometheus-stack-prometheus.${MONITORING_NAMESPACE}.svc.cluster.local:9090"
log_info "Grafana:    kube-prometheus-stack-grafana.${MONITORING_NAMESPACE}.svc.cluster.local:80"
log_info "Alertmanager: alertmanager-kube-prometheus-stack-alertmanager.${MONITORING_NAMESPACE}.svc.cluster.local:9093"
