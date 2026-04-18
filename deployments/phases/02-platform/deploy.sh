#!/usr/bin/env bash
################################################################################
# deploy.sh - Phase 02: Platform
#
# Full orchestrator for deploying the EKS platform layer:
#   0. Prerequisites check
#   1. Retrieve Phase 01 outputs
#   2. Terraform init/plan/apply
#   3. Update kubeconfig
#   4. Install EKS managed add-ons
#   5. Install Helm charts
#   6. Apply Kubernetes manifests
#   7. Configure Karpenter
#   8. Validate deployment
#
# Flags:
#   --plan-only       Run terraform plan without applying
#   --skip-terraform  Skip terraform (apply only K8s resources)
#   --skip-validate   Skip validation step
#   --destroy         Destroy all Phase 02 resources
#   --auto-approve    Skip confirmation prompts
################################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

PLAN_ONLY=false
SKIP_TERRAFORM=false
SKIP_VALIDATE=false
DESTROY=false
AUTO_APPROVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan-only)      PLAN_ONLY=true; shift ;;
        --skip-terraform) SKIP_TERRAFORM=true; shift ;;
        --skip-validate)  SKIP_VALIDATE=true; shift ;;
        --destroy)        DESTROY=true; shift ;;
        --auto-approve)   AUTO_APPROVE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--plan-only] [--skip-terraform] [--skip-validate] [--destroy] [--auto-approve]"
            exit 0
            ;;
        *)
            die "Unknown flag: $1. Use --help for usage."
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: terraform output from this phase
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 0: Prerequisites check
# ---------------------------------------------------------------------------

check_prereqs() {
    step_start "Check prerequisites"

    local missing=()

    command -v terraform &>/dev/null || missing+=("terraform")
    command -v aws       &>/dev/null || missing+=("aws")
    command -v kubectl   &>/dev/null || missing+=("kubectl")
    command -v helm      &>/dev/null || missing+=("helm")
    command -v jq        &>/dev/null || missing+=("jq")

    if (( ${#missing[@]} > 0 )); then
        die "Missing required tools: ${missing[*]}"
    fi

    # Verify minimum terraform version
    local tf_version
    tf_version="$(terraform version -json | jq -r '.terraform_version')"
    log_info "Terraform version: ${tf_version}"

    # Verify minimum kubectl version
    local kubectl_version
    kubectl_version="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || echo "unknown")"
    log_info "kubectl version: ${kubectl_version}"

    # Verify minimum helm version
    local helm_version
    helm_version="$(helm version --short 2>/dev/null || echo "unknown")"
    log_info "Helm version: ${helm_version}"

    log_success "All prerequisites satisfied"
    step_end
}

check_aws_auth() {
    step_start "Verify AWS authentication"

    local identity
    identity="$(aws sts get-caller-identity --output json 2>/dev/null)" || \
        die "AWS authentication failed. Run 'aws configure' or set AWS_PROFILE."

    local account_id arn
    account_id="$(echo "${identity}" | jq -r '.Account')"
    arn="$(echo "${identity}" | jq -r '.Arn')"

    log_info "AWS Account: ${account_id}"
    log_info "AWS Identity: ${arn}"

    log_success "AWS authentication verified"
    step_end
}

# ---------------------------------------------------------------------------
# Step 1: Retrieve Phase 01 outputs
# ---------------------------------------------------------------------------

retrieve_phase01_outputs() {
    step_start "Retrieve Phase 01 (Foundation) outputs"

    # Verify Phase 01 state exists by checking a known output
    local vpc_id
    vpc_id="$(cd "${TERRAFORM_DIR}" && terraform output -raw vpc_id 2>/dev/null || echo "")"

    # If terraform outputs are not available yet (before init), we can
    # verify Phase 01 state via the S3 backend
    log_info "Phase 01 outputs will be loaded via terraform_remote_state data source"
    log_info "Verifying Phase 01 state file exists..."

    aws s3api head-object \
        --bucket "isaac-lab-prod-terraform-state" \
        --key "phases/foundation/terraform.tfstate" \
        --region "${AWS_REGION:-us-east-1}" &>/dev/null || \
        die "Phase 01 (Foundation) state not found. Deploy Phase 01 first."

    log_success "Phase 01 state file verified"
    step_end
}

# ---------------------------------------------------------------------------
# Step 2: Terraform init/plan/apply
# ---------------------------------------------------------------------------

run_terraform() {
    step_start "Terraform init"
    terraform -chdir="${TERRAFORM_DIR}" init -upgrade
    step_end

    step_start "Terraform plan"
    terraform -chdir="${TERRAFORM_DIR}" plan \
        -out="${TERRAFORM_DIR}/tfplan" \
        -detailed-exitcode || {
            local exit_code=$?
            if [[ ${exit_code} -eq 2 ]]; then
                log_info "Terraform plan contains changes"
            elif [[ ${exit_code} -eq 0 ]]; then
                log_info "No changes detected"
                if [[ "${PLAN_ONLY}" == "true" ]]; then
                    log_success "Plan-only mode: exiting"
                    return 0
                fi
            else
                die "Terraform plan failed"
            fi
        }
    step_end

    if [[ "${PLAN_ONLY}" == "true" ]]; then
        log_success "Plan-only mode: review the plan above"
        return 0
    fi

    # Confirm before apply
    if [[ "${AUTO_APPROVE}" != "true" ]]; then
        confirm "Apply terraform changes?" || {
            log_warn "Terraform apply cancelled by user"
            exit 0
        }
    fi

    step_start "Terraform apply"
    terraform -chdir="${TERRAFORM_DIR}" apply "${TERRAFORM_DIR}/tfplan"
    rm -f "${TERRAFORM_DIR}/tfplan"
    step_end
}

# ---------------------------------------------------------------------------
# Step 2b: Terraform destroy
# ---------------------------------------------------------------------------

run_terraform_destroy() {
    step_start "Terraform destroy"

    terraform -chdir="${TERRAFORM_DIR}" init -upgrade

    if [[ "${AUTO_APPROVE}" != "true" ]]; then
        confirm "DESTROY all Phase 02 resources? This cannot be undone." || {
            log_warn "Destroy cancelled by user"
            exit 0
        }
    fi

    terraform -chdir="${TERRAFORM_DIR}" destroy \
        ${AUTO_APPROVE:+-auto-approve}

    log_success "Phase 02 resources destroyed"
    step_end
}

# ---------------------------------------------------------------------------
# Step 3: Update kubeconfig
# ---------------------------------------------------------------------------

update_kubeconfig() {
    step_start "Update kubeconfig"

    local cluster_name
    cluster_name="$(get_tf_output cluster_name)"
    local region="${AWS_REGION:-us-east-1}"

    aws eks update-kubeconfig \
        --name "${cluster_name}" \
        --region "${region}" \
        --alias "${cluster_name}"

    # Verify connectivity
    retry 5 5 kubectl cluster-info

    log_success "kubeconfig updated for cluster: ${cluster_name}"
    step_end
}

# ---------------------------------------------------------------------------
# Step 4: Install EKS managed add-ons
# ---------------------------------------------------------------------------

install_eks_addons() {
    step_start "Install EKS managed add-ons"
    bash "${SCRIPTS_DIR}/install-eks-addons.sh"
    step_end
}

# ---------------------------------------------------------------------------
# Step 5: Install Helm charts
# ---------------------------------------------------------------------------

install_helm_charts() {
    step_start "Install Helm charts"
    bash "${SCRIPTS_DIR}/install-helm-charts.sh"
    step_end
}

# ---------------------------------------------------------------------------
# Step 6: Apply Kubernetes manifests
# ---------------------------------------------------------------------------

apply_manifests() {
    step_start "Apply Kubernetes manifests"

    # 6a. gp3 StorageClass
    log_info "Applying gp3 StorageClass..."
    kubectl apply -f "${MANIFESTS_DIR}/gp3-storageclass.yaml"

    # 6b. FSx PV/PVC (substitute terraform outputs)
    log_info "Applying FSx PV/PVC..."
    local fsx_id fsx_mount_name aws_region
    fsx_id="$(get_tf_output fsx_filesystem_id)"
    fsx_mount_name="$(get_tf_output fsx_mount_name)"
    aws_region="${AWS_REGION:-us-east-1}"

    sed -e "s/FSX_FILESYSTEM_ID/${fsx_id}/g" \
        -e "s/FSX_MOUNT_NAME/${fsx_mount_name}/g" \
        -e "s/us-east-1/${aws_region}/g" \
        "${MANIFESTS_DIR}/fsx-pv-pvc.yaml" | \
        kubectl apply -f -

    # 6c. ClusterSecretStore (substitute region)
    log_info "Applying ClusterSecretStore..."
    sed "s/AWS_REGION/${aws_region}/g" \
        "${MANIFESTS_DIR}/cluster-secretstore.yaml" | \
        kubectl apply -f -

    log_success "All Kubernetes manifests applied"
    step_end
}

# ---------------------------------------------------------------------------
# Step 7: Configure Karpenter
# ---------------------------------------------------------------------------

configure_karpenter() {
    step_start "Configure Karpenter"
    bash "${SCRIPTS_DIR}/configure-karpenter.sh"
    step_end
}

# ---------------------------------------------------------------------------
# Step 8: Validate deployment
# ---------------------------------------------------------------------------

validate_deployment() {
    step_start "Validate deployment"
    bash "${SCRIPTS_DIR}/validate.sh"
    step_end
}

# ===========================================================================
# Main execution
# ===========================================================================

main() {
    phase_start "Phase 02: Platform"

    local exit_code=0

    # Handle destroy mode
    if [[ "${DESTROY}" == "true" ]]; then
        check_prereqs
        check_aws_auth
        run_terraform_destroy
        phase_end 0
        return 0
    fi

    # Step 0: Prerequisites
    check_prereqs
    check_aws_auth

    # Step 1: Verify Phase 01
    retrieve_phase01_outputs

    # Step 2: Terraform
    if [[ "${SKIP_TERRAFORM}" != "true" ]]; then
        run_terraform
        if [[ "${PLAN_ONLY}" == "true" ]]; then
            phase_end 0
            return 0
        fi
    else
        log_info "Skipping terraform (--skip-terraform)"
    fi

    # Step 3: kubeconfig
    update_kubeconfig

    # Step 4: EKS add-ons
    install_eks_addons

    # Step 5: Helm charts
    install_helm_charts

    # Step 6: Kubernetes manifests
    apply_manifests

    # Step 7: Karpenter configuration
    configure_karpenter

    # Step 8: Validation
    if [[ "${SKIP_VALIDATE}" != "true" ]]; then
        validate_deployment
    else
        log_info "Skipping validation (--skip-validate)"
    fi

    phase_end ${exit_code}
}

main "$@"
