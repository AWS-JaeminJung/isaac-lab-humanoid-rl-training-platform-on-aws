#!/usr/bin/env bash
################################################################################
# build-training-image.sh
#
# Builds the production training image and pushes it to ECR:
#   1. Authenticate with ECR
#   2. Build image from docker/Dockerfile
#   3. Tag as ${ECR_REPO_URL}/isaac-lab-training:v1.0.0
#   4. Push to ECR
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PHASE_DIR}/docker"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs from Phase 02 (platform)
# ---------------------------------------------------------------------------

PLATFORM_TERRAFORM_DIR="${PHASE_DIR}/../02-platform/terraform"

get_tf_output() {
    terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

ECR_REPO_URL="$(get_tf_output ecr_repository_url)"
AWS_REGION="${AWS_REGION:-$(get_tf_output aws_region 2>/dev/null || echo "us-east-1")}"
AWS_ACCOUNT_ID="$(echo "${ECR_REPO_URL}" | cut -d'.' -f1)"

IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"
FULL_IMAGE="${ECR_REPO_URL}/isaac-lab-training:${IMAGE_TAG}"

log_info "ECR Repository URL: ${ECR_REPO_URL}"
log_info "Image tag:          ${IMAGE_TAG}"
log_info "Full image:         ${FULL_IMAGE}"

# ===========================================================================
# 1. Authenticate with ECR
# ===========================================================================

step_start "ECR authentication"

aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log_success "Authenticated with ECR"
step_end

# ===========================================================================
# 2. Build production training image
# ===========================================================================

step_start "Build training image"

docker build \
    --platform linux/amd64 \
    -t "${FULL_IMAGE}" \
    -t "${ECR_REPO_URL}/isaac-lab-training:latest" \
    -f "${DOCKER_DIR}/Dockerfile" \
    "${DOCKER_DIR}"

log_success "Image built: ${FULL_IMAGE}"
step_end

# ===========================================================================
# 3. Push to ECR
# ===========================================================================

step_start "Push image to ECR"

docker push "${FULL_IMAGE}"
docker push "${ECR_REPO_URL}/isaac-lab-training:latest"

log_success "Image pushed: ${FULL_IMAGE}"
step_end

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "=============================================================================="
echo "  Training Image Build Summary"
echo "=============================================================================="
echo "  Image:    ${FULL_IMAGE}"
echo "  Latest:   ${ECR_REPO_URL}/isaac-lab-training:latest"
echo "  Registry: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo "=============================================================================="
echo ""

log_success "Training image built and pushed successfully"
