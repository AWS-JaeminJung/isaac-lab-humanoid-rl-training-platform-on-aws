#!/usr/bin/env bash
################################################################################
# Phase 05 - Orchestrator: Deployment Script
#
# Deploys NVIDIA OSMO Controller and KubeRay Operator for workflow orchestration.
# Configures RBAC and runs CPU-mode pipeline verification.
#
# Usage:
#   ./deploy.sh                  # Full deploy
#   ./deploy.sh --plan-only      # Terraform plan only
#   ./deploy.sh --skip-validate  # Deploy without validation
#   ./deploy.sh --destroy        # Destroy Phase 05 resources
#
# Prerequisites:
#   - Phase 2 completed (EKS, Karpenter)
#   - Phase 4 completed (Keycloak OIDC clients: osmo-api, ray-dashboard)
#   - Training image pushed to ECR
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
VALIDATE_SCRIPT="${SCRIPT_DIR}/scripts/validate.sh"

LIB_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/prereqs.sh"
source "${LIB_DIR}/terraform.sh"
source "${LIB_DIR}/helm.sh"
source "${LIB_DIR}/kubectl.sh"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

PLAN_ONLY=false
SKIP_VALIDATE=false
DESTROY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan-only)     PLAN_ONLY=true;     shift ;;
        --skip-validate) SKIP_VALIDATE=true; shift ;;
        --destroy)       DESTROY=true;       shift ;;
        -h|--help)
            echo "Usage: $0 [--plan-only] [--skip-validate] [--destroy]"
            exit 0
            ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

phase_start "05 - Orchestrator (OSMO + KubeRay)"

step_start "Check prerequisites"
check_prereqs
step_end $?

step_start "Verify AWS authentication"
check_aws_auth
step_end $?

if [[ "${DESTROY}" == "true" ]]; then
    step_start "Terraform destroy"
    tf_init "${TF_DIR}"
    tf_destroy "${TF_DIR}"
    step_end $?
    phase_end 0
    exit 0
fi

# Step 1: Terraform - OSMO/KubeRay namespaces, RBAC, Ingress
step_start "Terraform init"
tf_init "${TF_DIR}"
step_end $?

step_start "Terraform plan"
tf_plan "${TF_DIR}"
step_end $?

if [[ "${PLAN_ONLY}" == "true" ]]; then
    log_info "Plan-only mode: stopping before apply."
    phase_end 0
    exit 0
fi

step_start "Terraform apply"
tf_apply "${TF_DIR}"
step_end $?

# Step 2: Install OSMO Controller
step_start "Install OSMO Controller"
if [[ -x "${SCRIPT_DIR}/scripts/install-osmo.sh" ]]; then
    "${SCRIPT_DIR}/scripts/install-osmo.sh"
fi
step_end $?

# Step 3: Install KubeRay Operator
step_start "Install KubeRay Operator"
if [[ -x "${SCRIPT_DIR}/scripts/install-kuberay.sh" ]]; then
    "${SCRIPT_DIR}/scripts/install-kuberay.sh"
fi
step_end $?

# Step 4: Apply RBAC and resource quotas
step_start "Apply RBAC and resource quotas"
if [[ -d "${SCRIPT_DIR}/manifests" ]]; then
    kube_apply "${SCRIPT_DIR}/manifests"
fi
step_end $?

# Step 5: CPU-mode pipeline verification
step_start "CPU-mode pipeline verification"
if [[ -x "${SCRIPT_DIR}/scripts/verify-cpu-pipeline.sh" ]]; then
    "${SCRIPT_DIR}/scripts/verify-cpu-pipeline.sh"
fi
step_end $?

# Step 6: Validation
if [[ "${SKIP_VALIDATE}" != "true" ]]; then
    step_start "Post-deploy validation"
    if [[ -x "${VALIDATE_SCRIPT}" ]]; then
        "${VALIDATE_SCRIPT}"
        step_end $?
    else
        log_warn "Validation script not found: ${VALIDATE_SCRIPT}"
        step_end 0
    fi
fi

phase_end 0
