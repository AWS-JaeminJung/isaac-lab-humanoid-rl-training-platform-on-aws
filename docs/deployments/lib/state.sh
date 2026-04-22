#!/usr/bin/env bash
################################################################################
# state.sh - Cross-phase Terraform output state management
#
# Provides cached access to Terraform outputs from different deployment phases.
# Avoids repeated terraform init + output calls by caching results in an
# associative array.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/state.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Output cache (associative array)
# Key format: "<phase_dir>::<output_key>"
# ---------------------------------------------------------------------------
declare -gA _OUTPUT_CACHE=()

# ---------------------------------------------------------------------------
# _cache_key - Build a consistent cache key
# ---------------------------------------------------------------------------
_cache_key() {
    local phase_dir="${1}"
    local output_key="${2}"
    # Resolve to absolute path for consistency
    local abs_dir
    abs_dir="$(cd "${phase_dir}" 2>/dev/null && pwd)" || abs_dir="${phase_dir}"
    echo "${abs_dir}::${output_key}"
}

# ---------------------------------------------------------------------------
# get_phase_output - Get a Terraform output from a phase directory
#
# Initializes Terraform in the phase directory if needed, then retrieves
# the specified output value.
#
# Usage: vpc_id="$(get_phase_output "./phases/01-foundation" "vpc_id")"
#        cluster_name="$(get_phase_output "./phases/02-platform" "cluster_name")"
#
# Parameters:
#   phase_dir  - Path to the Terraform directory for the phase
#   output_key - Name of the Terraform output to retrieve
#
# Outputs the raw value to stdout. Dies on failure.
# ---------------------------------------------------------------------------
get_phase_output() {
    local phase_dir="${1:?phase directory required}"
    local output_key="${2:?output key required}"

    if [[ ! -d "${phase_dir}" ]]; then
        die "Phase directory does not exist: ${phase_dir}"
    fi

    # Initialize Terraform if not already done
    if [[ ! -d "${phase_dir}/.terraform" ]]; then
        log_info "Initializing Terraform in ${phase_dir} for output retrieval..."
        if ! terraform -chdir="${phase_dir}" init -input=false -backend=true &>/dev/null; then
            die "Terraform init failed in ${phase_dir}"
        fi
    fi

    # Retrieve the output
    local value
    if ! value="$(terraform -chdir="${phase_dir}" output -raw "${output_key}" 2>/dev/null)"; then
        die "Failed to get output '${output_key}' from ${phase_dir}. Has this phase been applied?"
    fi

    if [[ -z "${value}" ]]; then
        die "Output '${output_key}' is empty in ${phase_dir}"
    fi

    echo "${value}"
}

# ---------------------------------------------------------------------------
# get_phase_output_cached - Cached version of get_phase_output
#
# Returns the cached value if available, otherwise fetches from Terraform
# and stores in cache.
#
# Usage: vpc_id="$(get_phase_output_cached "./phases/01-foundation" "vpc_id")"
# ---------------------------------------------------------------------------
get_phase_output_cached() {
    local phase_dir="${1:?phase directory required}"
    local output_key="${2:?output key required}"

    local key
    key="$(_cache_key "${phase_dir}" "${output_key}")"

    # Check cache first
    if [[ -n "${_OUTPUT_CACHE[${key}]+_}" ]]; then
        log_debug "Cache hit: ${output_key} from ${phase_dir}"
        echo "${_OUTPUT_CACHE[${key}]}"
        return 0
    fi

    # Cache miss - fetch from Terraform
    log_debug "Cache miss: ${output_key} from ${phase_dir}"
    local value
    value="$(get_phase_output "${phase_dir}" "${output_key}")"

    # Store in cache
    _OUTPUT_CACHE["${key}"]="${value}"

    echo "${value}"
}

# ---------------------------------------------------------------------------
# invalidate_cache - Clear the entire output cache or a specific entry
# Usage: invalidate_cache                                    # clear all
#        invalidate_cache "./phases/01-foundation" "vpc_id"  # clear one
# ---------------------------------------------------------------------------
invalidate_cache() {
    if (( $# == 0 )); then
        log_debug "Clearing entire output cache (${#_OUTPUT_CACHE[@]} entries)"
        _OUTPUT_CACHE=()
    else
        local phase_dir="${1}"
        local output_key="${2}"
        local key
        key="$(_cache_key "${phase_dir}" "${output_key}")"
        unset "_OUTPUT_CACHE[${key}]"
        log_debug "Invalidated cache: ${output_key} from ${phase_dir}"
    fi
}

# ---------------------------------------------------------------------------
# cache_status - Print current cache contents (for debugging)
# ---------------------------------------------------------------------------
cache_status() {
    local count=${#_OUTPUT_CACHE[@]}
    log_info "Output cache: ${count} entries"
    if (( count > 0 )); then
        for key in "${!_OUTPUT_CACHE[@]}"; do
            local phase_dir="${key%%::*}"
            local output_key="${key##*::}"
            local value="${_OUTPUT_CACHE[${key}]}"
            # Truncate long values for display
            if (( ${#value} > 60 )); then
                value="${value:0:57}..."
            fi
            log_debug "  ${output_key} (${phase_dir}): ${value}"
        done
    fi
}

# ---------------------------------------------------------------------------
# Convenience functions for common cross-phase lookups
# ---------------------------------------------------------------------------

# Get Phase 1 (Foundation) outputs
get_vpc_id()            { get_phase_output_cached "${REPO_ROOT}/phases/01-foundation" "vpc_id"; }
get_gpu_subnet_id()     { get_phase_output_cached "${REPO_ROOT}/phases/01-foundation" "gpu_subnet_id"; }
get_mgmt_subnet_id()    { get_phase_output_cached "${REPO_ROOT}/phases/01-foundation" "management_subnet_id"; }
get_infra_subnet_id()   { get_phase_output_cached "${REPO_ROOT}/phases/01-foundation" "infrastructure_subnet_id"; }
get_hosted_zone_id()    { get_phase_output_cached "${REPO_ROOT}/phases/01-foundation" "hosted_zone_id"; }

# Get Phase 2 (Platform) outputs
get_cluster_name()      { get_phase_output_cached "${REPO_ROOT}/phases/02-platform" "cluster_name"; }
get_cluster_endpoint()  { get_phase_output_cached "${REPO_ROOT}/phases/02-platform" "cluster_endpoint"; }
get_oidc_provider_arn() { get_phase_output_cached "${REPO_ROOT}/phases/02-platform" "oidc_provider_arn"; }
get_rds_endpoint()      { get_phase_output_cached "${REPO_ROOT}/phases/02-platform" "rds_endpoint"; }
get_fsx_dns_name()      { get_phase_output_cached "${REPO_ROOT}/phases/02-platform" "fsx_dns_name"; }
get_fsx_mount_name()    { get_phase_output_cached "${REPO_ROOT}/phases/02-platform" "fsx_mount_name"; }
