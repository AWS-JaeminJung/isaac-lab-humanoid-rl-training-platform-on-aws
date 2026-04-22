#!/usr/bin/env bash
################################################################################
# terraform.sh - Terraform wrapper functions
#
# Provides init, plan, apply, output, and destroy operations with consistent
# error handling and logging.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/terraform.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# tf_init - Initialize Terraform in the given directory
# Usage: tf_init "/path/to/terraform/dir"
# ---------------------------------------------------------------------------
tf_init() {
    local tf_dir="${1:?terraform directory required}"

    if [[ ! -d "${tf_dir}" ]]; then
        die "Terraform directory does not exist: ${tf_dir}"
    fi

    log_info "Terraform init: ${tf_dir}"

    local init_args=(-input=false)

    # Use backend config if a backend.hcl exists
    if [[ -f "${tf_dir}/backend.hcl" ]]; then
        init_args+=(-backend-config="${tf_dir}/backend.hcl")
    fi

    # Reconfigure if .terraform already exists (idempotent)
    if [[ -d "${tf_dir}/.terraform" ]]; then
        init_args+=(-reconfigure)
    fi

    if ! terraform -chdir="${tf_dir}" init "${init_args[@]}"; then
        die "Terraform init failed in ${tf_dir}"
    fi

    log_success "Terraform initialized: ${tf_dir}"
}

# ---------------------------------------------------------------------------
# tf_plan - Generate a Terraform plan
# Usage: tf_plan "/path/to/tf/dir" [extra_var_file1 extra_var_file2 ...]
#
# Automatically merges:
#   1. config/base.tfvars         (if it exists)
#   2. config/env/${TF_ENV}.tfvars (if TF_ENV is set and file exists)
#   3. Any extra var files passed as arguments
#
# Outputs the plan to ${tf_dir}/tfplan
# ---------------------------------------------------------------------------
tf_plan() {
    local tf_dir="${1:?terraform directory required}"
    shift
    local extra_var_files=("$@")

    log_info "Terraform plan: ${tf_dir}"

    local plan_args=(-input=false -out="${tf_dir}/tfplan")

    # Base tfvars
    local base_tfvars="${REPO_ROOT}/config/base.tfvars"
    if [[ -f "${base_tfvars}" ]]; then
        plan_args+=(-var-file="${base_tfvars}")
        log_debug "Using base vars: ${base_tfvars}"
    fi

    # Environment-specific tfvars
    local env="${TF_ENV:-production}"
    local env_tfvars="${REPO_ROOT}/config/env/${env}.tfvars"
    if [[ -f "${env_tfvars}" ]]; then
        plan_args+=(-var-file="${env_tfvars}")
        log_debug "Using env vars: ${env_tfvars}"
    fi

    # Extra var files
    for var_file in "${extra_var_files[@]}"; do
        if [[ -f "${var_file}" ]]; then
            plan_args+=(-var-file="${var_file}")
            log_debug "Using extra vars: ${var_file}"
        else
            log_warn "Var file not found, skipping: ${var_file}"
        fi
    done

    if ! terraform -chdir="${tf_dir}" plan "${plan_args[@]}"; then
        die "Terraform plan failed in ${tf_dir}"
    fi

    log_success "Terraform plan saved: ${tf_dir}/tfplan"
}

# ---------------------------------------------------------------------------
# tf_apply - Apply a previously generated Terraform plan
# Usage: tf_apply "/path/to/tf/dir"
# ---------------------------------------------------------------------------
tf_apply() {
    local tf_dir="${1:?terraform directory required}"
    local plan_file="${tf_dir}/tfplan"

    if [[ ! -f "${plan_file}" ]]; then
        die "No plan file found at ${plan_file}. Run tf_plan first."
    fi

    log_info "Terraform apply: ${tf_dir}"

    if ! terraform -chdir="${tf_dir}" apply -input=false "${plan_file}"; then
        die "Terraform apply failed in ${tf_dir}"
    fi

    # Clean up plan file after successful apply
    rm -f "${plan_file}"
    log_success "Terraform apply complete: ${tf_dir}"
}

# ---------------------------------------------------------------------------
# tf_output - Get a specific Terraform output value
# Usage: tf_output "/path/to/tf/dir" "output_key"
# Prints the raw output value to stdout
# ---------------------------------------------------------------------------
tf_output() {
    local tf_dir="${1:?terraform directory required}"
    local key="${2:?output key required}"

    if [[ ! -d "${tf_dir}/.terraform" ]]; then
        log_debug "Terraform not initialized in ${tf_dir}, running init..."
        tf_init "${tf_dir}"
    fi

    local value
    if ! value="$(terraform -chdir="${tf_dir}" output -raw "${key}" 2>/dev/null)"; then
        die "Failed to get Terraform output '${key}' from ${tf_dir}"
    fi

    if [[ -z "${value}" ]]; then
        die "Terraform output '${key}' is empty in ${tf_dir}"
    fi

    echo "${value}"
}

# ---------------------------------------------------------------------------
# tf_destroy - Destroy Terraform-managed infrastructure (with confirmation)
# Usage: tf_destroy "/path/to/tf/dir"
# ---------------------------------------------------------------------------
tf_destroy() {
    local tf_dir="${1:?terraform directory required}"

    log_warn "About to DESTROY infrastructure in: ${tf_dir}"
    echo "" >&2
    echo -e "${_CLR_RED}${_CLR_BOLD}  WARNING: This action is IRREVERSIBLE.${_CLR_RESET}" >&2
    echo -e "${_CLR_RED}  All resources managed by ${tf_dir} will be permanently deleted.${_CLR_RESET}" >&2
    echo "" >&2

    confirm "Type 'y' to confirm destruction" || {
        log_info "Destruction cancelled"
        return 0
    }

    # Double confirmation for safety
    local dir_name
    dir_name="$(basename "${tf_dir}")"
    echo -en "${_CLR_RED}  Type the directory name '${dir_name}' to confirm: ${_CLR_RESET}" >&2
    local response
    read -r response
    if [[ "${response}" != "${dir_name}" ]]; then
        log_info "Destruction cancelled (name mismatch)"
        return 0
    fi

    log_info "Terraform destroy: ${tf_dir}"

    local destroy_args=(-input=false -auto-approve)

    # Include var files for destroy (same merge logic as plan)
    local base_tfvars="${REPO_ROOT}/config/base.tfvars"
    if [[ -f "${base_tfvars}" ]]; then
        destroy_args+=(-var-file="${base_tfvars}")
    fi

    local env="${TF_ENV:-production}"
    local env_tfvars="${REPO_ROOT}/config/env/${env}.tfvars"
    if [[ -f "${env_tfvars}" ]]; then
        destroy_args+=(-var-file="${env_tfvars}")
    fi

    if ! terraform -chdir="${tf_dir}" destroy "${destroy_args[@]}"; then
        die "Terraform destroy failed in ${tf_dir}"
    fi

    log_success "Terraform destroy complete: ${tf_dir}"
}
