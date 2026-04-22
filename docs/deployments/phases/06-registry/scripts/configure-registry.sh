#!/usr/bin/env bash
################################################################################
# configure-registry.sh
#
# Configures MLflow model registry defaults:
#   1. Creates a default experiment ("isaac-lab-default")
#   2. Verifies the MLflow API is responsive
#   3. Sets up initial tracking configuration
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

# Use the in-cluster service URL for configuration
MLFLOW_INTERNAL_URL="http://mlflow.${MLFLOW_NAMESPACE}.svc.cluster.local:5000"

# For API calls, use kubectl port-forward in the background
MLFLOW_LOCAL_PORT=15000
log_info "Starting port-forward to MLflow service..."

kubectl port-forward svc/mlflow \
    -n "${MLFLOW_NAMESPACE}" \
    "${MLFLOW_LOCAL_PORT}:5000" &
PF_PID=$!

# Ensure port-forward is cleaned up on exit
cleanup() {
    if kill -0 "${PF_PID}" 2>/dev/null; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Wait for port-forward to be ready
sleep 3

MLFLOW_API="http://localhost:${MLFLOW_LOCAL_PORT}"

# ===========================================================================
# 1. Verify MLflow API is Responsive
# ===========================================================================

step_start "Verify MLflow API"

MAX_RETRIES=10
RETRY_INTERVAL=5
RETRY_COUNT=0

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    if curl -sf --max-time 5 "${MLFLOW_API}/api/2.0/mlflow/experiments/search" >/dev/null 2>&1; then
        log_success "MLflow API is responsive"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
        die "MLflow API did not become responsive after ${MAX_RETRIES} attempts"
    fi

    log_info "MLflow API not ready, retrying (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep "${RETRY_INTERVAL}"
done

step_end

# ===========================================================================
# 2. Create Default Experiment
# ===========================================================================

step_start "Create default experiment"

# Check if the default experiment already exists
EXISTING_EXPERIMENT="$(curl -sf --max-time 10 \
    "${MLFLOW_API}/api/2.0/mlflow/experiments/get-by-name?experiment_name=isaac-lab-default" \
    2>/dev/null || true)"

if [[ -n "${EXISTING_EXPERIMENT}" ]] && echo "${EXISTING_EXPERIMENT}" | jq -e '.experiment' >/dev/null 2>&1; then
    EXPERIMENT_ID="$(echo "${EXISTING_EXPERIMENT}" | jq -r '.experiment.experiment_id')"
    log_info "Default experiment 'isaac-lab-default' already exists (ID: ${EXPERIMENT_ID})"
else
    log_info "Creating default experiment 'isaac-lab-default'..."

    CREATE_RESPONSE="$(curl -sf --max-time 10 \
        -X POST "${MLFLOW_API}/api/2.0/mlflow/experiments/create" \
        -H "Content-Type: application/json" \
        -d '{"name": "isaac-lab-default"}' 2>/dev/null || true)"

    if [[ -n "${CREATE_RESPONSE}" ]] && echo "${CREATE_RESPONSE}" | jq -e '.experiment_id' >/dev/null 2>&1; then
        EXPERIMENT_ID="$(echo "${CREATE_RESPONSE}" | jq -r '.experiment_id')"
        log_success "Default experiment created (ID: ${EXPERIMENT_ID})"
    else
        log_warn "Could not create default experiment. Response: ${CREATE_RESPONSE:-empty}"
    fi
fi

step_end

# ===========================================================================
# 3. Create Training Experiment
# ===========================================================================

step_start "Create training experiment"

EXISTING_TRAINING="$(curl -sf --max-time 10 \
    "${MLFLOW_API}/api/2.0/mlflow/experiments/get-by-name?experiment_name=isaac-lab-training" \
    2>/dev/null || true)"

if [[ -n "${EXISTING_TRAINING}" ]] && echo "${EXISTING_TRAINING}" | jq -e '.experiment' >/dev/null 2>&1; then
    TRAINING_ID="$(echo "${EXISTING_TRAINING}" | jq -r '.experiment.experiment_id')"
    log_info "Training experiment 'isaac-lab-training' already exists (ID: ${TRAINING_ID})"
else
    log_info "Creating training experiment 'isaac-lab-training'..."

    CREATE_TRAINING="$(curl -sf --max-time 10 \
        -X POST "${MLFLOW_API}/api/2.0/mlflow/experiments/create" \
        -H "Content-Type: application/json" \
        -d '{"name": "isaac-lab-training"}' 2>/dev/null || true)"

    if [[ -n "${CREATE_TRAINING}" ]] && echo "${CREATE_TRAINING}" | jq -e '.experiment_id' >/dev/null 2>&1; then
        TRAINING_ID="$(echo "${CREATE_TRAINING}" | jq -r '.experiment_id')"
        log_success "Training experiment created (ID: ${TRAINING_ID})"
    else
        log_warn "Could not create training experiment. Response: ${CREATE_TRAINING:-empty}"
    fi
fi

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "MLflow registry configuration complete"
log_info "Default experiment: isaac-lab-default"
log_info "Training experiment: isaac-lab-training"
