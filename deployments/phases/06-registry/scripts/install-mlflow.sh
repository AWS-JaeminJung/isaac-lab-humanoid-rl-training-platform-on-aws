#!/usr/bin/env bash
################################################################################
# install-mlflow.sh
#
# Deploys the MLflow tracking server as a Kubernetes Deployment + Service:
#   - Reads RDS endpoint, S3 bucket, and IRSA role ARN from Terraform outputs
#   - Applies mlflow-deployment.yaml (envsubst with S3_MODELS_BUCKET)
#   - Applies mlflow-service.yaml
#   - Waits for the deployment to become ready
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

MLFLOW_NAMESPACE="$(get_tf_output mlflow_namespace)"
RDS_ENDPOINT="$(get_tf_output rds_endpoint)"
RDS_PORT="$(get_tf_output rds_port)"
S3_MODELS_BUCKET="$(get_tf_output s3_models_bucket)"
IRSA_MLFLOW_ROLE_ARN="$(get_tf_output irsa_mlflow_role_arn)"

log_info "Namespace:        ${MLFLOW_NAMESPACE}"
log_info "RDS:              ${RDS_ENDPOINT}:${RDS_PORT}"
log_info "S3 Models Bucket: ${S3_MODELS_BUCKET}"
log_info "IRSA Role ARN:    ${IRSA_MLFLOW_ROLE_ARN}"

# ===========================================================================
# 1. Apply MLflow Deployment Manifest
# ===========================================================================

step_start "Apply MLflow Deployment"

export S3_MODELS_BUCKET
envsubst < "${MANIFESTS_DIR}/mlflow-deployment.yaml" | kubectl apply -f -

log_info "MLflow Deployment manifest applied"
step_end

# ===========================================================================
# 2. Apply MLflow Service Manifest
# ===========================================================================

step_start "Apply MLflow Service"

kubectl apply -f "${MANIFESTS_DIR}/mlflow-service.yaml"

log_info "MLflow Service manifest applied"
step_end

# ===========================================================================
# 3. Wait for Deployment Ready
# ===========================================================================

step_start "Wait for MLflow Deployment to be ready"

MAX_WAIT=300
log_info "Waiting up to ${MAX_WAIT}s for mlflow deployment to become ready..."

if kubectl rollout status deployment/mlflow \
    -n "${MLFLOW_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "MLflow deployment is ready"
else
    die "MLflow deployment did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "MLflow deployment complete"
log_info "MLflow is available at http://mlflow.${MLFLOW_NAMESPACE}.svc.cluster.local:5000"
