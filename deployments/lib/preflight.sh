#!/usr/bin/env bash
################################################################################
# preflight.sh - Phase-specific prerequisite validation
#
# Each preflight_phaseXX() function checks everything the phase needs before
# starting: prior phase outputs, required secrets, services, connectivity.
# On failure, prints a clear, actionable message telling the operator exactly
# what to fix and how.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"
################################################################################

# Source dependencies
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./prereqs.sh
source "$(dirname "${BASH_SOURCE[0]}")/prereqs.sh"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_preflight_errors=()

_preflight_check() {
    local description="$1"
    shift
    if "$@" &>/dev/null; then
        printf "  ${_CLR_GREEN}✓${_CLR_RESET} %s\n" "${description}" >&2
    else
        printf "  ${_CLR_RED}✗${_CLR_RESET} %s\n" "${description}" >&2
        return 1
    fi
}

_preflight_fail() {
    local description="$1"
    local hint="$2"
    printf "  ${_CLR_RED}✗${_CLR_RESET} %s\n" "${description}" >&2
    printf "    ${_CLR_YELLOW}→ %s${_CLR_RESET}\n" "${hint}" >&2
    _preflight_errors+=("${description}")
}

_preflight_ok() {
    local description="$1"
    printf "  ${_CLR_GREEN}✓${_CLR_RESET} %s\n" "${description}" >&2
}

_preflight_header() {
    local phase_name="$1"
    echo "" >&2
    echo -e "${_CLR_BOLD}Pre-flight checks: ${phase_name}${_CLR_RESET}" >&2
    echo -e "${_CLR_DIM}────────────────────────────────────────────────${_CLR_RESET}" >&2
    _preflight_errors=()
}

_preflight_summary() {
    echo "" >&2
    if (( ${#_preflight_errors[@]} > 0 )); then
        echo -e "${_CLR_RED}${_CLR_BOLD}Pre-flight FAILED — ${#_preflight_errors[@]} issue(s) must be resolved:${_CLR_RESET}" >&2
        echo "" >&2
        local i=1
        for err in "${_preflight_errors[@]}"; do
            echo -e "  ${_CLR_RED}${i}. ${err}${_CLR_RESET}" >&2
            ((i++))
        done
        echo "" >&2
        die "Fix the above issues and re-run the deploy script."
    else
        log_success "All pre-flight checks passed"
    fi
}

# Check S3 backend bucket exists
_check_tf_backend() {
    local bucket="isaac-lab-prod-terraform-state"
    local table="isaac-lab-prod-terraform-locks"

    if aws s3api head-bucket --bucket "${bucket}" &>/dev/null; then
        _preflight_ok "Terraform state bucket exists (s3://${bucket})"
    else
        _preflight_fail "Terraform state bucket not found: s3://${bucket}" \
            "Create it first: aws s3 mb s3://${bucket} --region \${AWS_REGION}"
    fi

    if aws dynamodb describe-table --table-name "${table}" &>/dev/null; then
        _preflight_ok "Terraform lock table exists (${table})"
    else
        _preflight_fail "DynamoDB lock table not found: ${table}" \
            "Create it: aws dynamodb create-table --table-name ${table} --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST"
    fi
}

# Check that a prior phase's Terraform state file exists in S3
_check_phase_state() {
    local phase_name="$1"
    local state_key="$2"
    local bucket="isaac-lab-prod-terraform-state"

    if aws s3api head-object --bucket "${bucket}" --key "${state_key}" &>/dev/null; then
        _preflight_ok "${phase_name} deployed (state: ${state_key})"
    else
        _preflight_fail "${phase_name} has not been deployed yet" \
            "Run Phase ${phase_name} first: cd phases/${phase_name}/ && ./deploy.sh"
    fi
}

# Check that secrets.env exists and has a specific key filled in
_check_secret() {
    local key="$1"
    local label="$2"
    local secrets_file="${REPO_ROOT}/config/secrets.env"

    if [[ ! -f "${secrets_file}" ]]; then
        _preflight_fail "secrets.env not found" \
            "Copy the template: cp config/secrets.env.example config/secrets.env  then fill in the values."
        return
    fi

    local value
    value="$(grep -E "^${key}=" "${secrets_file}" 2>/dev/null | head -1 | cut -d'=' -f2-)"
    if [[ -n "${value}" && "${value}" != '""' && "${value}" != "''" ]]; then
        _preflight_ok "${label} is set in secrets.env"
    else
        _preflight_fail "${label} is empty in secrets.env (key: ${key})" \
            "Edit config/secrets.env and set a value for ${key}"
    fi
}

# Check that a Kubernetes namespace exists
_check_k8s_namespace() {
    local ns="$1"
    if kubectl get namespace "${ns}" &>/dev/null; then
        _preflight_ok "Kubernetes namespace '${ns}' exists"
    else
        _preflight_fail "Kubernetes namespace '${ns}' does not exist" \
            "Ensure the previous phase that creates '${ns}' has been deployed."
    fi
}

# Check that a Helm release is deployed
_check_helm_release() {
    local release="$1"
    local namespace="$2"
    if helm status "${release}" -n "${namespace}" &>/dev/null; then
        _preflight_ok "Helm release '${release}' deployed in '${namespace}'"
    else
        _preflight_fail "Helm release '${release}' not found in namespace '${namespace}'" \
            "Deploy the required service first."
    fi
}

# Check that a Kubernetes deployment/statefulset is ready
_check_k8s_ready() {
    local resource="$1"
    local namespace="$2"
    if kubectl rollout status "${resource}" -n "${namespace}" --timeout=5s &>/dev/null; then
        _preflight_ok "${resource} is ready in '${namespace}'"
    else
        _preflight_fail "${resource} is not ready in '${namespace}'" \
            "Check: kubectl describe ${resource} -n ${namespace}"
    fi
}

# Check ECR image exists
_check_ecr_image() {
    local repo="$1"
    local tag="${2:-latest}"
    local region="${AWS_REGION:-us-east-1}"

    if aws ecr describe-images --repository-name "${repo}" --image-ids imageTag="${tag}" --region "${region}" &>/dev/null; then
        _preflight_ok "ECR image ${repo}:${tag} exists"
    else
        _preflight_fail "ECR image ${repo}:${tag} not found" \
            "Build and push the image: docker build -t ${repo}:${tag} . && docker push <ECR_URI>/${repo}:${tag}"
    fi
}

# ===========================================================================
# Phase-specific preflight functions
# ===========================================================================

preflight_phase01() {
    _preflight_header "Phase 01 — Foundation"

    # 1. CLI tools
    if ! check_prereqs; then
        _preflight_fail "Required CLI tools are missing or outdated" \
            "Run: auto_install_prereqs  (or install them manually — see the table above)"
    fi

    # 2. AWS auth
    if aws sts get-caller-identity &>/dev/null; then
        _preflight_ok "AWS credentials are valid"
    else
        _preflight_fail "AWS authentication failed" \
            "Configure AWS credentials: aws configure  or  export AWS_PROFILE=<profile>"
    fi

    # 3. Terraform backend
    _check_tf_backend

    # 4. secrets.env
    local secrets_file="${REPO_ROOT}/config/secrets.env"
    if [[ -f "${secrets_file}" ]]; then
        _preflight_ok "secrets.env exists"
    else
        _preflight_fail "secrets.env not found" \
            "cp config/secrets.env.example config/secrets.env  then fill in required values."
    fi

    # 5. Direct Connect Gateway ID
    _check_secret "DX_GATEWAY_ID" "Direct Connect Gateway ID"

    _preflight_summary
}

preflight_phase02() {
    _preflight_header "Phase 02 — Platform (EKS + Storage)"

    # 1. AWS auth
    if aws sts get-caller-identity &>/dev/null; then
        _preflight_ok "AWS credentials are valid"
    else
        _preflight_fail "AWS authentication failed" \
            "Configure AWS credentials: aws configure  or  export AWS_PROFILE=<profile>"
    fi

    # 2. Terraform backend
    _check_tf_backend

    # 3. Phase 01 must be deployed
    _check_phase_state "01-foundation" "phases/foundation/terraform.tfstate"

    # 4. Secrets
    _check_secret "RDS_MASTER_PASSWORD" "RDS master password"

    _preflight_summary
}

preflight_phase03() {
    _preflight_header "Phase 03 — Bridge (EKS Hybrid Nodes)"

    # 1. AWS auth
    if aws sts get-caller-identity &>/dev/null; then
        _preflight_ok "AWS credentials are valid"
    else
        _preflight_fail "AWS authentication failed" \
            "Configure AWS credentials: aws configure  or  export AWS_PROFILE=<profile>"
    fi

    # 2. Phase 02 must be deployed
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"

    # 3. Kubeconfig must work
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Update kubeconfig: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 4. DX connectivity
    local onprem_gw="${ONPREM_GATEWAY_IP:-10.200.0.1}"
    if ping -c 1 -W 2 "${onprem_gw}" &>/dev/null; then
        _preflight_ok "On-Prem gateway reachable via Direct Connect (${onprem_gw})"
    else
        _preflight_fail "Cannot reach On-Prem gateway (${onprem_gw})" \
            "Check Direct Connect status and VGW route propagation. Set ONPREM_GATEWAY_IP if the default IP is wrong."
    fi

    _preflight_summary
}

preflight_phase04() {
    _preflight_header "Phase 04 — Gate (Keycloak)"

    # 1. Phase 02 must be deployed (EKS, RDS, ALB Controller)
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"

    # 2. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 3. RDS PostgreSQL reachable
    local rds_endpoint
    rds_endpoint="$(grep -E "^RDS_ENDPOINT=" "${REPO_ROOT}/config/secrets.env" 2>/dev/null | cut -d'=' -f2-)"
    if [[ -n "${rds_endpoint}" ]]; then
        _preflight_ok "RDS endpoint configured: ${rds_endpoint}"
    else
        _preflight_fail "RDS endpoint not configured in secrets.env" \
            "After Phase 02 deploy, add RDS_ENDPOINT=<endpoint> to config/secrets.env (or read it from: terraform -chdir=phases/02-platform/terraform output -raw rds_endpoint)"
    fi

    # 4. Secrets
    _check_secret "KEYCLOAK_DB_PASSWORD" "Keycloak DB password"
    _check_secret "KEYCLOAK_ADMIN_PASSWORD" "Keycloak admin password"

    # 5. LDAP/AD info
    _check_secret "LDAP_CONNECTION_URL" "LDAP connection URL"
    _check_secret "LDAP_BIND_DN" "LDAP Bind DN"
    _check_secret "LDAP_BIND_PASSWORD" "LDAP Bind password"

    # 6. TLS certificate
    _check_secret "TLS_CERTIFICATE_ARN" "ACM TLS certificate ARN"

    _preflight_summary
}

preflight_phase05() {
    _preflight_header "Phase 05 — Orchestrator (OSMO + KubeRay)"

    # 1. Phase 02 deployed
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"

    # 2. Phase 04 deployed (Keycloak for OIDC)
    _check_phase_state "04-gate" "phases/gate/terraform.tfstate"

    # 3. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 4. Keycloak running
    _check_helm_release "keycloak" "keycloak"

    # 5. OIDC client secrets
    _check_secret "KEYCLOAK_CLIENT_SECRET_OSMO" "Keycloak OIDC client secret for OSMO"

    # 6. Training image in ECR
    _check_ecr_image "isaac-lab-training" "latest"

    _preflight_summary
}

preflight_phase06() {
    _preflight_header "Phase 06 — Registry (MLflow)"

    # 1. Phase 02 deployed (RDS, S3, IRSA)
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"

    # 2. Phase 04 deployed (Keycloak OIDC)
    _check_phase_state "04-gate" "phases/gate/terraform.tfstate"

    # 3. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 4. Secrets
    _check_secret "MLFLOW_DB_PASSWORD" "MLflow DB password"
    _check_secret "KEYCLOAK_CLIENT_SECRET_MLFLOW" "Keycloak OIDC client secret for MLflow"

    _preflight_summary
}

preflight_phase07() {
    _preflight_header "Phase 07 — Recorder (ClickHouse + Fluent Bit)"

    # 1. Phase 02 deployed (EKS, EBS CSI Driver)
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"

    # 2. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 3. gp3 StorageClass
    if kubectl get storageclass gp3 &>/dev/null; then
        _preflight_ok "StorageClass 'gp3' exists"
    else
        _preflight_fail "StorageClass 'gp3' not found" \
            "Ensure Phase 02 created it. Check: kubectl get storageclass"
    fi

    # 4. ClickHouse credentials
    _check_secret "CLICKHOUSE_ADMIN_PASSWORD" "ClickHouse admin password"

    _preflight_summary
}

preflight_phase08() {
    _preflight_header "Phase 08 — Control Room (Prometheus + Grafana)"

    # 1. Phase 02 deployed
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"

    # 2. Phase 04 deployed (Keycloak OIDC for Grafana)
    _check_phase_state "04-gate" "phases/gate/terraform.tfstate"

    # 3. Phase 07 deployed (ClickHouse as Grafana data source)
    _check_phase_state "07-recorder" "phases/recorder/terraform.tfstate"

    # 4. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 5. Secrets
    _check_secret "GRAFANA_ADMIN_PASSWORD" "Grafana admin password"
    _check_secret "KEYCLOAK_CLIENT_SECRET_GRAFANA" "Keycloak OIDC client secret for Grafana"

    # 6. Slack webhooks (optional but warn)
    local secrets_file="${REPO_ROOT}/config/secrets.env"
    local slack_critical
    slack_critical="$(grep -E "^SLACK_WEBHOOK_CRITICAL=" "${secrets_file}" 2>/dev/null | cut -d'=' -f2-)"
    if [[ -z "${slack_critical}" ]]; then
        printf "  ${_CLR_YELLOW}⚠${_CLR_RESET} Slack webhook not configured (optional) — alerts will not be routed to Slack\n" >&2
        printf "    ${_CLR_DIM}→ Set SLACK_WEBHOOK_CRITICAL in config/secrets.env for alert routing${_CLR_RESET}\n" >&2
    else
        _preflight_ok "Slack webhook configured for critical alerts"
    fi

    _preflight_summary
}

preflight_phase09() {
    _preflight_header "Phase 09 — Lobby (JupyterHub)"

    # 1. Phase 04 deployed (Keycloak OIDC)
    _check_phase_state "04-gate" "phases/gate/terraform.tfstate"

    # 2. Phase 05 deployed (OSMO API)
    _check_phase_state "05-orchestrator" "phases/orchestrator/terraform.tfstate"

    # 3. Phase 06 deployed (MLflow)
    _check_phase_state "06-registry" "phases/registry/terraform.tfstate"

    # 4. Phase 07 deployed (ClickHouse)
    _check_phase_state "07-recorder" "phases/recorder/terraform.tfstate"

    # 5. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 6. Secrets
    _check_secret "KEYCLOAK_CLIENT_SECRET_JUPYTERHUB" "Keycloak OIDC client secret for JupyterHub"

    _preflight_summary
}

preflight_phase10() {
    _preflight_header "Phase 10 — Factory Floor (GPU Training)"

    # 1. All prior phases
    _check_phase_state "01-foundation" "phases/foundation/terraform.tfstate"
    _check_phase_state "02-platform" "phases/platform/terraform.tfstate"
    _check_phase_state "05-orchestrator" "phases/orchestrator/terraform.tfstate"
    _check_phase_state "06-registry" "phases/registry/terraform.tfstate"
    _check_phase_state "07-recorder" "phases/recorder/terraform.tfstate"
    _check_phase_state "08-control-room" "phases/control-room/terraform.tfstate"

    # 2. Kubeconfig
    if kubectl cluster-info &>/dev/null; then
        _preflight_ok "kubectl can connect to the EKS cluster"
    else
        _preflight_fail "Cannot connect to EKS cluster" \
            "Run: aws eks update-kubeconfig --name isaac-lab-production --region \${AWS_REGION}"
    fi

    # 3. OSMO controller running
    _check_helm_release "osmo-controller" "osmo-system"

    # 4. KubeRay operator running
    _check_helm_release "kuberay-operator" "ray-system"

    # 5. Karpenter GPU NodePool exists
    if kubectl get nodepool gpu-ondemand &>/dev/null 2>&1 || kubectl get nodepool gpu &>/dev/null 2>&1; then
        _preflight_ok "Karpenter GPU NodePool exists"
    else
        _preflight_fail "Karpenter GPU NodePool not found" \
            "Ensure Phase 02 created the GPU NodePool. Check: kubectl get nodepool"
    fi

    # 6. Training image in ECR
    _check_ecr_image "isaac-lab-training" "latest"

    _preflight_summary
}
