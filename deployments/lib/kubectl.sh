#!/usr/bin/env bash
################################################################################
# kubectl.sh - Kubernetes helper functions
#
# Provides: kube_apply, kube_wait_ready, kube_namespace_ensure,
#           kube_secret_exists.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/kubectl.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# kube_apply - Apply Kubernetes manifests from a file or directory
# Usage: kube_apply "/path/to/manifest.yaml"
#        kube_apply "/path/to/manifests/"
# ---------------------------------------------------------------------------
kube_apply() {
    local file_or_dir="${1:?file or directory path required}"

    if [[ ! -e "${file_or_dir}" ]]; then
        die "Path does not exist: ${file_or_dir}"
    fi

    log_info "Applying Kubernetes manifests: ${file_or_dir}"

    if ! kubectl apply -f "${file_or_dir}"; then
        die "kubectl apply failed: ${file_or_dir}"
    fi

    log_success "Applied: ${file_or_dir}"
}

# ---------------------------------------------------------------------------
# kube_wait_ready - Wait for a resource to become ready
# Usage: kube_wait_ready "deployment/my-app" "my-namespace" 300
#        kube_wait_ready "statefulset/clickhouse" "logging" 600
#
# Uses rollout status for deployments/statefulsets/daemonsets,
# and kubectl wait for other resource types.
# ---------------------------------------------------------------------------
kube_wait_ready() {
    local resource="${1:?resource required (e.g., deployment/my-app)}"
    local namespace="${2:?namespace required}"
    local timeout_seconds="${3:-300}"

    log_info "Waiting for ${resource} in ${namespace} to be ready (timeout: ${timeout_seconds}s)..."

    local resource_type="${resource%%/*}"

    case "${resource_type}" in
        deployment|statefulset|daemonset)
            if ! kubectl rollout status "${resource}" \
                --namespace "${namespace}" \
                --timeout="${timeout_seconds}s"; then
                die "Rollout not ready: ${resource} in ${namespace}"
            fi
            ;;
        pod)
            if ! kubectl wait "${resource}" \
                --namespace "${namespace}" \
                --for=condition=Ready \
                --timeout="${timeout_seconds}s"; then
                die "Pod not ready: ${resource} in ${namespace}"
            fi
            ;;
        job)
            if ! kubectl wait "${resource}" \
                --namespace "${namespace}" \
                --for=condition=Complete \
                --timeout="${timeout_seconds}s"; then
                die "Job not complete: ${resource} in ${namespace}"
            fi
            ;;
        *)
            # Generic wait for conditions
            if ! kubectl wait "${resource}" \
                --namespace "${namespace}" \
                --for=condition=Ready \
                --timeout="${timeout_seconds}s" 2>/dev/null; then
                # Fallback: check existence
                if kubectl get "${resource}" --namespace "${namespace}" &>/dev/null; then
                    log_warn "Resource ${resource} exists but Ready condition unavailable"
                else
                    die "Resource not found: ${resource} in ${namespace}"
                fi
            fi
            ;;
    esac

    log_success "Ready: ${resource} in ${namespace}"
}

# ---------------------------------------------------------------------------
# kube_namespace_ensure - Create a namespace if it does not exist
# Uses dry-run + apply pattern for idempotency
# Usage: kube_namespace_ensure "my-namespace"
#        kube_namespace_ensure "my-namespace" '{"label-key": "label-value"}'
# ---------------------------------------------------------------------------
kube_namespace_ensure() {
    local namespace="${1:?namespace required}"
    local labels="${2:-}"

    log_info "Ensuring namespace exists: ${namespace}"

    # Idempotent: create via dry-run then apply
    if ! kubectl create namespace "${namespace}" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        die "Failed to ensure namespace: ${namespace}"
    fi

    # Apply labels if provided
    if [[ -n "${labels}" ]]; then
        local key value
        while IFS='=' read -r key value; do
            kubectl label namespace "${namespace}" "${key}=${value}" --overwrite
        done <<< "${labels}"
    fi

    log_success "Namespace ready: ${namespace}"
}

# ---------------------------------------------------------------------------
# kube_secret_exists - Check if a Kubernetes secret exists
# Usage: kube_secret_exists "my-secret" "my-namespace"
# Returns 0 if exists, 1 otherwise
# ---------------------------------------------------------------------------
kube_secret_exists() {
    local name="${1:?secret name required}"
    local namespace="${2:?namespace required}"

    if kubectl get secret "${name}" --namespace "${namespace}" &>/dev/null; then
        log_debug "Secret exists: ${name} in ${namespace}"
        return 0
    else
        log_debug "Secret not found: ${name} in ${namespace}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# kube_create_secret_from_literal - Create or update a secret from key=value pairs
# Usage: kube_create_secret_from_literal "my-secret" "my-namespace" "key1=val1" "key2=val2"
# ---------------------------------------------------------------------------
kube_create_secret_from_literal() {
    local name="${1:?secret name required}"
    local namespace="${2:?namespace required}"
    shift 2

    if (( $# == 0 )); then
        die "At least one key=value pair required"
    fi

    local literal_args=()
    for kv in "$@"; do
        literal_args+=(--from-literal="${kv}")
    done

    log_info "Creating/updating secret: ${name} in ${namespace}"

    kubectl create secret generic "${name}" \
        --namespace "${namespace}" \
        "${literal_args[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "Secret ready: ${name} in ${namespace}"
}

# ---------------------------------------------------------------------------
# kube_get_pods - List pods matching a label selector
# Usage: kube_get_pods "app=my-app" "my-namespace"
# ---------------------------------------------------------------------------
kube_get_pods() {
    local selector="${1:?label selector required}"
    local namespace="${2:?namespace required}"

    kubectl get pods \
        --namespace "${namespace}" \
        --selector "${selector}" \
        --no-headers \
        -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,READY:.status.conditions[?(@.type=='Ready')].status,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp"
}
