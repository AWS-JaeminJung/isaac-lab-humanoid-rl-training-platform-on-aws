#!/usr/bin/env bash
################################################################################
# Phase 08 - Control Room: Deployment Script
#
# Deploys kube-prometheus-stack (Prometheus + Grafana + Alertmanager),
# DCGM Exporter for GPU monitoring, and configures Grafana dashboards
# with Prometheus + ClickHouse data sources.
#
# Usage:
#   ./deploy.sh                  # Full deploy
#   ./deploy.sh --plan-only      # Terraform plan only
#   ./deploy.sh --skip-validate  # Deploy without validation
#   ./deploy.sh --destroy        # Destroy Phase 08 resources
#
# Prerequisites:
#   - Phase 2 completed (EKS, EBS CSI Driver)
#   - Phase 4 completed (Keycloak OIDC client: grafana)
#   - Phase 7 completed (ClickHouse running)
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

phase_start "08 - Control Room (Prometheus + Grafana)"

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

# Step 1: Terraform - Monitoring namespace, Ingress, Route53
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

# Step 2: Deploy kube-prometheus-stack
step_start "Deploy kube-prometheus-stack"
if [[ -x "${SCRIPT_DIR}/scripts/install-monitoring-stack.sh" ]]; then
    "${SCRIPT_DIR}/scripts/install-monitoring-stack.sh"
fi
step_end $?

# Step 3: Deploy DCGM Exporter
step_start "Deploy DCGM Exporter"
if [[ -x "${SCRIPT_DIR}/scripts/install-dcgm-exporter.sh" ]]; then
    "${SCRIPT_DIR}/scripts/install-dcgm-exporter.sh"
fi
step_end $?

# Step 4: Configure Grafana data sources and dashboards
step_start "Configure Grafana dashboards"
if [[ -x "${SCRIPT_DIR}/scripts/configure-grafana.sh" ]]; then
    "${SCRIPT_DIR}/scripts/configure-grafana.sh"
fi
step_end $?

# Step 5: Configure Alertmanager routing
step_start "Configure alert routing"
if [[ -x "${SCRIPT_DIR}/scripts/configure-alerts.sh" ]]; then
    "${SCRIPT_DIR}/scripts/configure-alerts.sh"
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
