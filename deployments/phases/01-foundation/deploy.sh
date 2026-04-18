#!/usr/bin/env bash
################################################################################
# Phase 01 - Foundation: Deployment Script
#
# Deploys the foundation layer: VPC, subnets, security groups, VPC endpoints,
# Direct Connect association, Route 53, and ACM certificates.
#
# Usage:
#   ./deploy.sh                  # Full deploy (init + plan + apply + validate)
#   ./deploy.sh --plan-only      # Run init + plan only (no apply)
#   ./deploy.sh --skip-validate  # Deploy without running validation
#   ./deploy.sh --destroy        # Destroy all foundation resources
#
# Environment variables:
#   TF_ENV      - Environment name for tfvars lookup (default: production)
#   TF_VAR_*    - Override any Terraform variable
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
VALIDATE_SCRIPT="${SCRIPT_DIR}/scripts/validate.sh"

# Source shared libraries
LIB_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/prereqs.sh"
source "${LIB_DIR}/terraform.sh"
source "${LIB_DIR}/preflight.sh"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

PLAN_ONLY=false
SKIP_VALIDATE=false
DESTROY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan-only)
            PLAN_ONLY=true
            shift
            ;;
        --skip-validate)
            SKIP_VALIDATE=true
            shift
            ;;
        --destroy)
            DESTROY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--plan-only] [--skip-validate] [--destroy]"
            echo ""
            echo "Flags:"
            echo "  --plan-only      Run terraform init + plan only (no apply)"
            echo "  --skip-validate  Skip post-deploy validation"
            echo "  --destroy        Destroy all Phase 01 resources"
            exit 0
            ;;
        *)
            die "Unknown argument: $1. Use --help for usage."
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

phase_start "01 - Foundation"

# Step 0: Pre-flight checks
step_start "Pre-flight checks"
preflight_phase01
step_end $?

# Handle destroy mode
if [[ "${DESTROY}" == "true" ]]; then
    step_start "Terraform destroy"
    tf_init "${TF_DIR}"
    tf_destroy "${TF_DIR}"
    step_end $?
    phase_end 0
    exit 0
fi

# Step 1: Terraform init + plan + apply
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

# Step 2: Validation
if [[ "${SKIP_VALIDATE}" == "true" ]]; then
    log_warn "Skipping validation (--skip-validate)."
else
    step_start "Post-deploy validation"
    if [[ -x "${VALIDATE_SCRIPT}" ]]; then
        "${VALIDATE_SCRIPT}"
        step_end $?
    else
        log_warn "Validation script not executable or not found: ${VALIDATE_SCRIPT}"
        log_warn "Run: chmod +x ${VALIDATE_SCRIPT}"
        step_end 0
    fi
fi

phase_end 0
