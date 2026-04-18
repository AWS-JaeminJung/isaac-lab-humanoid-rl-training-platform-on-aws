#!/usr/bin/env bash
################################################################################
# helm.sh - Helm wrapper functions
#
# Provides idempotent Helm operations: repo management, install/upgrade with
# consistent timeout and wait behavior.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/helm.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Default Helm settings
# ---------------------------------------------------------------------------
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
HELM_ATOMIC="${HELM_ATOMIC:-false}"

# ---------------------------------------------------------------------------
# helm_repo_add - Idempotent Helm repo add + update
# Usage: helm_repo_add "karpenter" "oci://public.ecr.aws/karpenter"
#        helm_repo_add "prometheus-community" "https://prometheus-community.github.io/helm-charts"
# ---------------------------------------------------------------------------
helm_repo_add() {
    local name="${1:?repo name required}"
    local url="${2:?repo url required}"

    # OCI repos do not need explicit 'helm repo add'
    if [[ "${url}" == oci://* ]]; then
        log_info "OCI repo '${name}' (${url}) - no explicit add needed"
        return 0
    fi

    log_info "Adding Helm repo: ${name} -> ${url}"

    if helm repo list 2>/dev/null | grep -q "^${name}[[:space:]]"; then
        log_debug "Repo '${name}' already exists, updating..."
    else
        if ! helm repo add "${name}" "${url}"; then
            die "Failed to add Helm repo: ${name} (${url})"
        fi
    fi

    if ! helm repo update "${name}"; then
        die "Failed to update Helm repo: ${name}"
    fi

    log_success "Helm repo ready: ${name}"
}

# ---------------------------------------------------------------------------
# helm_install_or_upgrade - Idempotent install/upgrade of a Helm release
# Usage: helm_install_or_upgrade "release" "chart" "namespace" "values.yaml" [extra_args...]
#
# Parameters:
#   release     - Helm release name
#   chart       - Chart reference (e.g., "karpenter/karpenter" or "oci://...")
#   namespace   - Kubernetes namespace (will be created if needed)
#   values_file - Path to values YAML file (use "" to skip)
#   extra_args  - Additional helm arguments (e.g., --set key=value, --version X.Y.Z)
# ---------------------------------------------------------------------------
helm_install_or_upgrade() {
    local release="${1:?release name required}"
    local chart="${2:?chart reference required}"
    local namespace="${3:?namespace required}"
    local values_file="${4:-}"
    shift 4 || shift $#
    local extra_args=("$@")

    log_info "Helm install/upgrade: ${release} (chart: ${chart}, namespace: ${namespace})"

    # Build Helm arguments
    local helm_args=(
        "${release}" "${chart}"
        --namespace "${namespace}"
        --create-namespace
        --wait
        --timeout "${HELM_TIMEOUT}"
    )

    if [[ "${HELM_ATOMIC}" == "true" ]]; then
        helm_args+=(--atomic)
    fi

    # Add values file if provided and exists
    if [[ -n "${values_file}" ]]; then
        if [[ -f "${values_file}" ]]; then
            helm_args+=(--values "${values_file}")
        else
            die "Values file not found: ${values_file}"
        fi
    fi

    # Add any extra arguments
    if (( ${#extra_args[@]} > 0 )); then
        helm_args+=("${extra_args[@]}")
    fi

    # Check if release exists - use upgrade --install for idempotency
    if helm status "${release}" --namespace "${namespace}" &>/dev/null; then
        log_info "Release '${release}' exists, upgrading..."
        if ! helm upgrade "${helm_args[@]}"; then
            die "Helm upgrade failed: ${release}"
        fi
        log_success "Helm upgrade complete: ${release}"
    else
        log_info "Release '${release}' not found, installing..."
        if ! helm install "${helm_args[@]}"; then
            die "Helm install failed: ${release}"
        fi
        log_success "Helm install complete: ${release}"
    fi
}

# ---------------------------------------------------------------------------
# helm_uninstall - Uninstall a Helm release if it exists
# Usage: helm_uninstall "release" "namespace"
# ---------------------------------------------------------------------------
helm_uninstall() {
    local release="${1:?release name required}"
    local namespace="${2:?namespace required}"

    if helm status "${release}" --namespace "${namespace}" &>/dev/null; then
        log_info "Uninstalling Helm release: ${release} (namespace: ${namespace})"
        if ! helm uninstall "${release}" --namespace "${namespace}" --wait; then
            die "Helm uninstall failed: ${release}"
        fi
        log_success "Helm uninstall complete: ${release}"
    else
        log_info "Release '${release}' not found in namespace '${namespace}', nothing to uninstall"
    fi
}

# ---------------------------------------------------------------------------
# helm_status - Show status of a Helm release
# Usage: helm_status "release" "namespace"
# Returns 0 if release is deployed, 1 otherwise
# ---------------------------------------------------------------------------
helm_status() {
    local release="${1:?release name required}"
    local namespace="${2:?namespace required}"

    if helm status "${release}" --namespace "${namespace}" &>/dev/null; then
        local revision
        revision="$(helm status "${release}" --namespace "${namespace}" -o json | jq -r '.version')"
        local chart
        chart="$(helm status "${release}" --namespace "${namespace}" -o json | jq -r '.chart')"
        log_info "Release '${release}': deployed (revision ${revision}, chart ${chart})"
        return 0
    else
        log_warn "Release '${release}' is not deployed in namespace '${namespace}'"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# helm_wait_ready - Wait for all pods in a Helm release to be ready
# Usage: helm_wait_ready "release" "namespace" [timeout_seconds]
# ---------------------------------------------------------------------------
helm_wait_ready() {
    local release="${1:?release name required}"
    local namespace="${2:?namespace required}"
    local timeout="${3:-300}"

    log_info "Waiting for release '${release}' pods to be ready (timeout: ${timeout}s)..."

    local selector="app.kubernetes.io/instance=${release}"
    if ! kubectl wait pods \
        --namespace "${namespace}" \
        --selector "${selector}" \
        --for=condition=Ready \
        --timeout="${timeout}s" 2>/dev/null; then
        log_warn "Some pods for release '${release}' may not be ready yet"
        kubectl get pods --namespace "${namespace}" --selector "${selector}" >&2
        return 1
    fi

    log_success "All pods for release '${release}' are ready"
}
