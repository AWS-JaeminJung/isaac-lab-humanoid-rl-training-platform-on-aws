#!/usr/bin/env bash
################################################################################
# build-notebook-image.sh
#
# Builds and pushes the custom JupyterHub notebook image to ECR:
#   1. Authenticates Docker to Amazon ECR
#   2. Builds the image from docker/Dockerfile
#   3. Tags as ${ECR_REPO_URL}/jupyterhub-notebook:v1.0.0
#   4. Pushes the image to ECR
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
DOCKER_DIR="${PHASE_DIR}/docker"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"
# shellcheck source=../../../../lib/aws.sh
source "${SCRIPT_DIR}/../../../lib/aws.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

ECR_REPO_URL="$(get_tf_output ecr_repository_url)"
AWS_REGION="${AWS_REGION:-us-east-1}"

IMAGE_NAME="jupyterhub-notebook"
IMAGE_TAG="v1.0.0"
FULL_IMAGE="${ECR_REPO_URL}/${IMAGE_NAME}:${IMAGE_TAG}"

log_info "ECR Repository URL: ${ECR_REPO_URL}"
log_info "Image:              ${FULL_IMAGE}"

# ===========================================================================
# 1. Authenticate Docker to ECR
# ===========================================================================

step_start "Authenticate Docker to ECR"

ACCOUNT_ID="$(aws_get_account_id)"
aws_ecr_login "${AWS_REGION}" "${ACCOUNT_ID}"

step_end

# ===========================================================================
# 2. Ensure ECR Repository Exists
# ===========================================================================

step_start "Ensure ECR repository exists"

aws_ecr_ensure_repo "${IMAGE_NAME}" "${AWS_REGION}"

step_end

# ===========================================================================
# 3. Build Docker Image
# ===========================================================================

step_start "Build notebook Docker image"

if [[ ! -f "${DOCKER_DIR}/Dockerfile" ]]; then
    die "Dockerfile not found: ${DOCKER_DIR}/Dockerfile"
fi

log_info "Building image: ${FULL_IMAGE}"

docker build \
    --tag "${FULL_IMAGE}" \
    --tag "${ECR_REPO_URL}/${IMAGE_NAME}:latest" \
    --file "${DOCKER_DIR}/Dockerfile" \
    "${DOCKER_DIR}"

log_success "Image built: ${FULL_IMAGE}"
step_end

# ===========================================================================
# 4. Push Image to ECR
# ===========================================================================

step_start "Push notebook image to ECR"

log_info "Pushing: ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

log_info "Pushing: ${ECR_REPO_URL}/${IMAGE_NAME}:latest"
docker push "${ECR_REPO_URL}/${IMAGE_NAME}:latest"

log_success "Image pushed to ECR: ${FULL_IMAGE}"
step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "Notebook image build and push complete"
log_info "Image: ${FULL_IMAGE}"
