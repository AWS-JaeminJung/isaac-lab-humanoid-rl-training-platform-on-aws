#!/usr/bin/env bash
################################################################################
# Phase 10 - Factory Floor: Deployment Script
#
# Builds and pushes the production training image, then runs the 4-stage GPU
# validation: 1 GPU -> Multi-GPU (8) -> Multi-Node (16) -> HPO (ASHA).
# Establishes performance baselines.
#
# Usage:
#   ./deploy.sh                  # Full deploy (image + all stages)
#   ./deploy.sh --image-only     # Build and push training image only
#   ./deploy.sh --stage 1        # Run specific stage (1, 2, 3, or 4)
#   ./deploy.sh --skip-validate  # Deploy without validation
#
# Prerequisites:
#   - Phase 1-9 all completed
#   - Production training image ready in ECR
#   - Karpenter GPU NodePool configured
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_SCRIPT="${SCRIPT_DIR}/scripts/validate.sh"

LIB_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/prereqs.sh"
source "${LIB_DIR}/kubectl.sh"
source "${LIB_DIR}/aws.sh"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

IMAGE_ONLY=false
SKIP_VALIDATE=false
STAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-only)    IMAGE_ONLY=true;    shift ;;
        --skip-validate) SKIP_VALIDATE=true; shift ;;
        --stage)         STAGE="$2";         shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--image-only] [--stage N] [--skip-validate]"
            echo ""
            echo "Stages:"
            echo "  1  Single GPU (1x g6e.xlarge)"
            echo "  2  Multi-GPU  (1x g6e.48xlarge, 8 GPUs)"
            echo "  3  Multi-Node (2x g6e.48xlarge, 16 GPUs)"
            echo "  4  HPO with ASHA scheduler"
            exit 0
            ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

phase_start "10 - Factory Floor (GPU Training)"

step_start "Check prerequisites"
check_prereqs
step_end $?

step_start "Verify AWS authentication"
check_aws_auth
step_end $?

# Step 1: Build and push training image
step_start "Build and push training image to ECR"
if [[ -x "${SCRIPT_DIR}/scripts/build-training-image.sh" ]]; then
    "${SCRIPT_DIR}/scripts/build-training-image.sh"
fi
step_end $?

if [[ "${IMAGE_ONLY}" == "true" ]]; then
    log_info "Image-only mode: stopping after image push."
    phase_end 0
    exit 0
fi

# Step 2: Stage 1 - Single GPU
if [[ -z "${STAGE}" || "${STAGE}" == "1" ]]; then
    step_start "Stage 1: Single GPU training (1x g6e.xlarge)"
    if [[ -x "${SCRIPT_DIR}/scripts/run-single-gpu.sh" ]]; then
        "${SCRIPT_DIR}/scripts/run-single-gpu.sh"
    fi
    step_end $?
fi

# Step 3: Stage 2 - Multi-GPU
if [[ -z "${STAGE}" || "${STAGE}" == "2" ]]; then
    step_start "Stage 2: Multi-GPU training (8 GPUs)"
    if [[ -x "${SCRIPT_DIR}/scripts/run-multi-gpu.sh" ]]; then
        "${SCRIPT_DIR}/scripts/run-multi-gpu.sh"
    fi
    step_end $?
fi

# Step 4: Stage 3 - Multi-Node
if [[ -z "${STAGE}" || "${STAGE}" == "3" ]]; then
    step_start "Stage 3: Multi-Node training (16 GPUs)"
    if [[ -x "${SCRIPT_DIR}/scripts/run-multi-node.sh" ]]; then
        "${SCRIPT_DIR}/scripts/run-multi-node.sh"
    fi
    step_end $?
fi

# Step 5: Stage 4 - HPO
if [[ -z "${STAGE}" || "${STAGE}" == "4" ]]; then
    step_start "Stage 4: HPO with ASHA scheduler"
    if [[ -x "${SCRIPT_DIR}/scripts/run-hpo.sh" ]]; then
        "${SCRIPT_DIR}/scripts/run-hpo.sh"
    fi
    step_end $?
fi

# Step 6: Validation
if [[ "${SKIP_VALIDATE}" != "true" ]]; then
    step_start "Post-deploy E2E validation"
    if [[ -x "${VALIDATE_SCRIPT}" ]]; then
        "${VALIDATE_SCRIPT}"
        step_end $?
    else
        log_warn "Validation script not found: ${VALIDATE_SCRIPT}"
        step_end 0
    fi
fi

phase_end 0
