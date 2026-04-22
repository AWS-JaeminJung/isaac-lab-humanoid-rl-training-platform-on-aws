#!/usr/bin/env bash
################################################################################
# configure-grafana.sh
#
# Configures Grafana via the Admin API:
#   1. Adds Prometheus data source (if not exists)
#   2. Adds ClickHouse data source (clickhouse.logging.svc.cluster.local:8123)
#   3. Imports dashboards from the dashboards/ directory
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
DASHBOARDS_DIR="${PHASE_DIR}/dashboards"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

MONITORING_NAMESPACE="$(get_tf_output monitoring_namespace)"

log_info "Namespace: ${MONITORING_NAMESPACE}"

# ---------------------------------------------------------------------------
# Retrieve Grafana admin credentials from Kubernetes secret
# ---------------------------------------------------------------------------

GRAFANA_USER="$(kubectl get secret grafana-admin-credentials \
    -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{.data.admin-user}' | base64 -d)"
GRAFANA_PASSWORD="$(kubectl get secret grafana-admin-credentials \
    -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{.data.admin-password}' | base64 -d)"

# ---------------------------------------------------------------------------
# Port-forward to Grafana service
# ---------------------------------------------------------------------------

GRAFANA_LOCAL_PORT=13000
log_info "Starting port-forward to Grafana service..."

kubectl port-forward svc/kube-prometheus-stack-grafana \
    -n "${MONITORING_NAMESPACE}" \
    "${GRAFANA_LOCAL_PORT}:80" &
PF_PID=$!

cleanup() {
    if kill -0 "${PF_PID}" 2>/dev/null; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Wait for port-forward to be ready
sleep 3

GRAFANA_API="http://localhost:${GRAFANA_LOCAL_PORT}/api"
GRAFANA_AUTH="${GRAFANA_USER}:${GRAFANA_PASSWORD}"

# ---------------------------------------------------------------------------
# Verify Grafana API is responsive
# ---------------------------------------------------------------------------

MAX_RETRIES=10
RETRY_INTERVAL=5
RETRY_COUNT=0

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    if curl -sf --max-time 5 -u "${GRAFANA_AUTH}" "${GRAFANA_API}/health" >/dev/null 2>&1; then
        log_success "Grafana API is responsive"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
        die "Grafana API did not become responsive after ${MAX_RETRIES} attempts"
    fi

    log_info "Grafana API not ready, retrying (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep "${RETRY_INTERVAL}"
done

# ===========================================================================
# 1. Add Prometheus Data Source
# ===========================================================================

step_start "Add Prometheus data source"

PROMETHEUS_DS_EXISTS=$(curl -sf --max-time 10 \
    -u "${GRAFANA_AUTH}" \
    "${GRAFANA_API}/datasources/name/Prometheus" 2>/dev/null || true)

if [[ -n "${PROMETHEUS_DS_EXISTS}" ]] && echo "${PROMETHEUS_DS_EXISTS}" | jq -e '.id' >/dev/null 2>&1; then
    log_info "Prometheus data source already exists (ID: $(echo "${PROMETHEUS_DS_EXISTS}" | jq -r '.id'))"
else
    log_info "Creating Prometheus data source..."

    PROM_RESPONSE=$(curl -sf --max-time 10 \
        -u "${GRAFANA_AUTH}" \
        -X POST "${GRAFANA_API}/datasources" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "Prometheus",
            "type": "prometheus",
            "access": "proxy",
            "url": "http://prometheus-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090",
            "isDefault": true,
            "jsonData": {
                "timeInterval": "15s",
                "httpMethod": "POST"
            }
        }' 2>/dev/null || true)

    if [[ -n "${PROM_RESPONSE}" ]] && echo "${PROM_RESPONSE}" | jq -e '.datasource.id' >/dev/null 2>&1; then
        log_success "Prometheus data source created (ID: $(echo "${PROM_RESPONSE}" | jq -r '.datasource.id'))"
    else
        log_warn "Could not create Prometheus data source. Response: ${PROM_RESPONSE:-empty}"
    fi
fi

step_end

# ===========================================================================
# 2. Add ClickHouse Data Source
# ===========================================================================

step_start "Add ClickHouse data source"

CLICKHOUSE_DS_EXISTS=$(curl -sf --max-time 10 \
    -u "${GRAFANA_AUTH}" \
    "${GRAFANA_API}/datasources/name/ClickHouse" 2>/dev/null || true)

if [[ -n "${CLICKHOUSE_DS_EXISTS}" ]] && echo "${CLICKHOUSE_DS_EXISTS}" | jq -e '.id' >/dev/null 2>&1; then
    log_info "ClickHouse data source already exists (ID: $(echo "${CLICKHOUSE_DS_EXISTS}" | jq -r '.id'))"
else
    log_info "Creating ClickHouse data source..."

    CH_RESPONSE=$(curl -sf --max-time 10 \
        -u "${GRAFANA_AUTH}" \
        -X POST "${GRAFANA_API}/datasources" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "ClickHouse",
            "type": "grafana-clickhouse-datasource",
            "access": "proxy",
            "url": "http://clickhouse.logging.svc.cluster.local:8123",
            "jsonData": {
                "defaultDatabase": "isaac_lab",
                "port": 9000,
                "protocol": "native"
            }
        }' 2>/dev/null || true)

    if [[ -n "${CH_RESPONSE}" ]] && echo "${CH_RESPONSE}" | jq -e '.datasource.id' >/dev/null 2>&1; then
        log_success "ClickHouse data source created (ID: $(echo "${CH_RESPONSE}" | jq -r '.datasource.id'))"
    else
        log_warn "Could not create ClickHouse data source. Response: ${CH_RESPONSE:-empty}"
    fi
fi

step_end

# ===========================================================================
# 3. Import Dashboards
# ===========================================================================

step_start "Import dashboards"

# Create the Isaac Lab folder if it does not exist
FOLDER_RESPONSE=$(curl -sf --max-time 10 \
    -u "${GRAFANA_AUTH}" \
    "${GRAFANA_API}/folders" 2>/dev/null || true)

FOLDER_UID=""
if [[ -n "${FOLDER_RESPONSE}" ]]; then
    FOLDER_UID=$(echo "${FOLDER_RESPONSE}" | jq -r '.[] | select(.title == "Isaac Lab") | .uid' 2>/dev/null || true)
fi

if [[ -z "${FOLDER_UID}" ]]; then
    log_info "Creating 'Isaac Lab' folder in Grafana..."
    CREATE_FOLDER=$(curl -sf --max-time 10 \
        -u "${GRAFANA_AUTH}" \
        -X POST "${GRAFANA_API}/folders" \
        -H "Content-Type: application/json" \
        -d '{"title": "Isaac Lab"}' 2>/dev/null || true)

    FOLDER_UID=$(echo "${CREATE_FOLDER}" | jq -r '.uid' 2>/dev/null || true)
    if [[ -n "${FOLDER_UID}" ]]; then
        log_success "Folder 'Isaac Lab' created (UID: ${FOLDER_UID})"
    else
        log_warn "Could not create folder. Dashboards will be imported to General."
    fi
else
    log_info "Folder 'Isaac Lab' already exists (UID: ${FOLDER_UID})"
fi

# Import each dashboard JSON file
DASHBOARD_COUNT=0
DASHBOARD_ERRORS=0

for DASHBOARD_FILE in "${DASHBOARDS_DIR}"/*.json; do
    if [[ ! -f "${DASHBOARD_FILE}" ]]; then
        log_warn "No dashboard JSON files found in ${DASHBOARDS_DIR}"
        break
    fi

    DASHBOARD_NAME="$(basename "${DASHBOARD_FILE}" .json)"
    log_info "Importing dashboard: ${DASHBOARD_NAME}..."

    # Build the import payload: wrap dashboard JSON with folderUid and overwrite flag
    IMPORT_PAYLOAD=$(jq -n \
        --argjson dashboard "$(cat "${DASHBOARD_FILE}")" \
        --arg folderUid "${FOLDER_UID}" \
        '{
            "dashboard": ($dashboard | .id = null),
            "folderUid": $folderUid,
            "overwrite": true
        }')

    IMPORT_RESPONSE=$(curl -sf --max-time 15 \
        -u "${GRAFANA_AUTH}" \
        -X POST "${GRAFANA_API}/dashboards/db" \
        -H "Content-Type: application/json" \
        -d "${IMPORT_PAYLOAD}" 2>/dev/null || true)

    if [[ -n "${IMPORT_RESPONSE}" ]] && echo "${IMPORT_RESPONSE}" | jq -e '.status == "success"' >/dev/null 2>&1; then
        DASHBOARD_URL=$(echo "${IMPORT_RESPONSE}" | jq -r '.url' 2>/dev/null || true)
        log_success "Dashboard imported: ${DASHBOARD_NAME} (${DASHBOARD_URL})"
        DASHBOARD_COUNT=$((DASHBOARD_COUNT + 1))
    else
        log_warn "Could not import dashboard: ${DASHBOARD_NAME}. Response: ${IMPORT_RESPONSE:-empty}"
        DASHBOARD_ERRORS=$((DASHBOARD_ERRORS + 1))
    fi
done

log_info "Dashboards imported: ${DASHBOARD_COUNT}, errors: ${DASHBOARD_ERRORS}"

step_end

# ===========================================================================
# Done
# ===========================================================================

# Clean up port-forward
cleanup
trap - EXIT

log_success "Grafana configuration complete"
log_info "Data sources: Prometheus (default), ClickHouse"
log_info "Dashboards imported: ${DASHBOARD_COUNT}"
