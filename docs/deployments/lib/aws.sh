#!/usr/bin/env bash
################################################################################
# aws.sh - AWS helper functions
#
# Provides: aws_ecr_login, aws_s3_test, aws_secretsmanager_get,
#           aws_update_kubeconfig.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/aws.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# aws_ecr_login - Authenticate Docker to Amazon ECR
# Usage: aws_ecr_login "us-east-1" "123456789012"
# ---------------------------------------------------------------------------
aws_ecr_login() {
    local region="${1:?region required}"
    local account_id="${2:?account_id required}"

    local registry="${account_id}.dkr.ecr.${region}.amazonaws.com"

    log_info "Authenticating Docker to ECR: ${registry}"

    if ! aws ecr get-login-password --region "${region}" | \
        docker login --username AWS --password-stdin "${registry}"; then
        die "ECR authentication failed for ${registry}"
    fi

    log_success "Docker authenticated to ECR: ${registry}"
}

# ---------------------------------------------------------------------------
# aws_s3_test - Test S3 bucket accessibility
# Usage: aws_s3_test "my-bucket-name"
#        aws_s3_test "s3://my-bucket-name/prefix/"
# Returns 0 if accessible, 1 otherwise
# ---------------------------------------------------------------------------
aws_s3_test() {
    local bucket="${1:?bucket required}"

    # Normalize: strip s3:// prefix if present, extract bucket name
    bucket="${bucket#s3://}"
    local bucket_name="${bucket%%/*}"

    log_info "Testing S3 access: s3://${bucket_name}"

    if ! aws s3 ls "s3://${bucket_name}/" --max-items 1 &>/dev/null; then
        log_error "Cannot access S3 bucket: ${bucket_name}"
        return 1
    fi

    log_success "S3 bucket accessible: ${bucket_name}"
    return 0
}

# ---------------------------------------------------------------------------
# aws_secretsmanager_get - Retrieve a secret value from AWS Secrets Manager
# Usage: aws_secretsmanager_get "my-secret-id" "us-east-1"
#
# Outputs the SecretString value to stdout.
# For JSON secrets, pipe to jq to extract specific keys.
# ---------------------------------------------------------------------------
aws_secretsmanager_get() {
    local secret_id="${1:?secret_id required}"
    local region="${2:?region required}"

    log_info "Retrieving secret: ${secret_id} (region: ${region})"

    local secret_value
    if ! secret_value="$(aws secretsmanager get-secret-value \
        --secret-id "${secret_id}" \
        --region "${region}" \
        --query 'SecretString' \
        --output text 2>&1)"; then
        die "Failed to retrieve secret '${secret_id}': ${secret_value}"
    fi

    if [[ -z "${secret_value}" || "${secret_value}" == "null" ]]; then
        die "Secret '${secret_id}' is empty or null"
    fi

    log_success "Secret retrieved: ${secret_id}"
    echo "${secret_value}"
}

# ---------------------------------------------------------------------------
# aws_update_kubeconfig - Update kubeconfig for an EKS cluster
# Usage: aws_update_kubeconfig "isaac-lab-production" "us-east-1"
#        aws_update_kubeconfig "isaac-lab-production" "us-east-1" "my-profile"
# ---------------------------------------------------------------------------
aws_update_kubeconfig() {
    local cluster_name="${1:?cluster_name required}"
    local region="${2:?region required}"
    local profile="${3:-}"

    log_info "Updating kubeconfig for EKS cluster: ${cluster_name} (region: ${region})"

    local args=(
        --name "${cluster_name}"
        --region "${region}"
    )

    if [[ -n "${profile}" ]]; then
        args+=(--profile "${profile}")
    fi

    if ! aws eks update-kubeconfig "${args[@]}"; then
        die "Failed to update kubeconfig for cluster: ${cluster_name}"
    fi

    # Verify connectivity
    local context
    context="$(kubectl config current-context 2>/dev/null)" || true

    log_success "kubeconfig updated for: ${cluster_name} (context: ${context})"
}

# ---------------------------------------------------------------------------
# aws_ecr_ensure_repo - Create ECR repository if it doesn't exist
# Usage: aws_ecr_ensure_repo "isaac-lab-training" "us-east-1"
# ---------------------------------------------------------------------------
aws_ecr_ensure_repo() {
    local repo_name="${1:?repository name required}"
    local region="${2:?region required}"

    log_info "Ensuring ECR repository exists: ${repo_name}"

    if aws ecr describe-repositories \
        --repository-names "${repo_name}" \
        --region "${region}" &>/dev/null; then
        log_debug "ECR repository already exists: ${repo_name}"
    else
        log_info "Creating ECR repository: ${repo_name}"
        if ! aws ecr create-repository \
            --repository-name "${repo_name}" \
            --region "${region}" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 &>/dev/null; then
            die "Failed to create ECR repository: ${repo_name}"
        fi
    fi

    log_success "ECR repository ready: ${repo_name}"
}

# ---------------------------------------------------------------------------
# aws_get_account_id - Get the current AWS account ID
# Usage: account_id="$(aws_get_account_id)"
# ---------------------------------------------------------------------------
aws_get_account_id() {
    aws sts get-caller-identity --query 'Account' --output text 2>/dev/null \
        || die "Failed to get AWS account ID"
}

# ---------------------------------------------------------------------------
# aws_get_region - Get the configured AWS region (with fallback)
# Usage: region="$(aws_get_region)"
# ---------------------------------------------------------------------------
aws_get_region() {
    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [[ -z "${region}" ]]; then
        region="$(aws configure get region 2>/dev/null)" || true
    fi
    if [[ -z "${region}" ]]; then
        region="us-east-1"
        log_warn "No AWS region configured, defaulting to ${region}"
    fi
    echo "${region}"
}
