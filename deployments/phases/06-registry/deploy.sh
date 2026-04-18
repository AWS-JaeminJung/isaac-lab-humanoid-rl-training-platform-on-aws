#!/usr/bin/env bash
################################################################################
# Phase 06 - Registry: Deployment Script
#
# Deploys MLflow for experiment tracking, model versioning, and S3 artifact
# storage. Configures OAuth2 Proxy for Keycloak OIDC authentication.
#
# Usage:
#   ./deploy.sh                  # Full deploy
#   ./deploy.sh --plan-only      # Terraform plan only
#   ./deploy.sh --skip-validate  # Deploy without validation
#   ./deploy.sh --destroy        # Destroy Phase 06 resources
#
# Prerequisites:
#   - Phase 2 completed (RDS mlflow_db, S3 models bucket, IRSA)
#   - Phase 4 completed (Keycloak OIDC client: mlflow)
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

phase_start "06 - Registry (MLflow)"

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

# Step 1: Terraform - ExternalSecret, Ingress, Route53
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

# Step 2: Deploy MLflow via Helm
step_start "Deploy MLflow"
if [[ -x "${SCRIPT_DIR}/scripts/install-mlflow.sh" ]]; then
    "${SCRIPT_DIR}/scripts/install-mlflow.sh"
fi
step_end $?

# Step 3: Deploy OAuth2 Proxy for MLflow
step_start "Deploy OAuth2 Proxy"
if [[ -x "${SCRIPT_DIR}/scripts/install-oauth2-proxy.sh" ]]; then
    "${SCRIPT_DIR}/scripts/install-oauth2-proxy.sh"
fi
step_end $?

# Step 4: Configure model lifecycle stages
step_start "Configure model registry"
if [[ -x "${SCRIPT_DIR}/scripts/configure-registry.sh" ]]; then
    "${SCRIPT_DIR}/scripts/configure-registry.sh"
fi
step_end $?

# Step 5: Validation
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
