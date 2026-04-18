#!/usr/bin/env bash
################################################################################
# install-osmo.sh
#
# Deploys NVIDIA OSMO Controller via Helm chart with:
#   - 2 replicas on management nodes
#   - External PostgreSQL (RDS) backend via ExternalSecret
#   - OIDC authentication via Keycloak
#   - IRSA role for S3 access
#   - Internal ALB Ingress with ACM TLS for OSMO API and Ray Dashboard
#   - Route53 alias records for both endpoints
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
MANIFESTS_DIR="${PHASE_DIR}/manifests"
CONFIG_DIR="$(cd "${PHASE_DIR}/../../.." && pwd)/docs/deployments/config/helm"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"
# shellcheck source=../../../../lib/helm.sh
source "${SCRIPT_DIR}/../../../lib/helm.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

ORCHESTRATION_NAMESPACE="$(get_tf_output orchestration_namespace)"
OSMO_HOSTNAME="$(get_tf_output osmo_hostname)"
RAY_DASHBOARD_HOSTNAME="$(get_tf_output ray_dashboard_hostname)"
OSMO_IRSA_ROLE_ARN="$(get_tf_output osmo_irsa_role_arn)"
ACM_CERT_ARN="$(get_tf_output acm_certificate_arn)"
HOSTED_ZONE_ID="$(get_tf_output hosted_zone_id)"
ECR_REPOSITORY_URL="$(get_tf_output ecr_repository_url)"
AWS_REGION="${AWS_REGION:-us-east-1}"
DOMAIN="${DOMAIN:-isaac-lab.internal}"

log_info "Namespace:      ${ORCHESTRATION_NAMESPACE}"
log_info "OSMO Hostname:  ${OSMO_HOSTNAME}"
log_info "Ray Dashboard:  ${RAY_DASHBOARD_HOSTNAME}"
log_info "IRSA Role ARN:  ${OSMO_IRSA_ROLE_ARN}"

# ===========================================================================
# 1. Add NVIDIA OSMO Helm Repository
# ===========================================================================

step_start "Add NVIDIA OSMO Helm repo"
helm_repo_add "nvidia-osmo" "https://helm.ngc.nvidia.com/nvidia/osmo"
step_end

# ===========================================================================
# 2. Install OSMO Controller via Helm
# ===========================================================================

step_start "Install OSMO Controller Helm chart"

VALUES_FILE="${CONFIG_DIR}/osmo-controller-values.yaml"

helm_install_or_upgrade "osmo-controller" \
    "nvidia-osmo/osmo-controller" \
    "${ORCHESTRATION_NAMESPACE}" \
    "${VALUES_FILE}" \
    --version "1.2.0" \
    --set "image.repository=nvcr.io/nvidia/osmo/osmo-controller" \
    --set "image.tag=1.2.0" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${OSMO_IRSA_ROLE_ARN}" \
    --set "config.oidc.issuerUrl=https://${OSMO_HOSTNAME%osmo.*}keycloak.${DOMAIN}/realms/isaac-lab-production" \
    --set "config.s3.checkpointBucket=$(get_tf_output ecr_repository_url | sed 's|.*/||' || echo '')" \
    --set "config.ray.defaultImage=${ECR_REPOSITORY_URL}/isaac-lab-training:latest"

step_end

# ===========================================================================
# 3. Wait for OSMO Controller to be Ready
# ===========================================================================

step_start "Wait for OSMO Controller pods"

kubectl rollout status deployment/osmo-controller \
    -n "${ORCHESTRATION_NAMESPACE}" \
    --timeout=180s

log_success "OSMO Controller is ready"
step_end

# ===========================================================================
# 4. Apply Ingress Manifests
# ===========================================================================

step_start "Apply OSMO API Ingress"

export ACM_CERT_ARN
export DOMAIN
envsubst < "${MANIFESTS_DIR}/osmo-ingress.yaml" | kubectl apply -f -

log_info "OSMO API Ingress applied"
step_end

step_start "Apply Ray Dashboard Ingress"

envsubst < "${MANIFESTS_DIR}/ray-dashboard-ingress.yaml" | kubectl apply -f -

log_info "Ray Dashboard Ingress applied"
step_end

# ===========================================================================
# 5. Wait for ALBs to be Provisioned
# ===========================================================================

step_start "Wait for ALBs"

MAX_WAIT=300
POLL_INTERVAL=10

# --- OSMO API ALB ---
OSMO_ALB_DNS=""
ELAPSED=0

while [[ -z "${OSMO_ALB_DNS}" && ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    OSMO_ALB_DNS="$(kubectl get ingress osmo-api \
        -n "${ORCHESTRATION_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [[ -z "${OSMO_ALB_DNS}" ]]; then
        log_info "OSMO ALB not yet provisioned (${ELAPSED}s/${MAX_WAIT}s)..."
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    fi
done

if [[ -z "${OSMO_ALB_DNS}" ]]; then
    die "OSMO ALB was not provisioned within ${MAX_WAIT}s. Check the ALB controller logs."
fi

log_success "OSMO ALB provisioned: ${OSMO_ALB_DNS}"

# --- Ray Dashboard ALB ---
RAY_ALB_DNS=""
ELAPSED=0

while [[ -z "${RAY_ALB_DNS}" && ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    RAY_ALB_DNS="$(kubectl get ingress ray-dashboard \
        -n "${ORCHESTRATION_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [[ -z "${RAY_ALB_DNS}" ]]; then
        log_info "Ray Dashboard ALB not yet provisioned (${ELAPSED}s/${MAX_WAIT}s)..."
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    fi
done

if [[ -z "${RAY_ALB_DNS}" ]]; then
    die "Ray Dashboard ALB was not provisioned within ${MAX_WAIT}s. Check the ALB controller logs."
fi

log_success "Ray Dashboard ALB provisioned: ${RAY_ALB_DNS}"

step_end

# ===========================================================================
# 6. Create Route53 Alias Records
# ===========================================================================

step_start "Create Route53 records"

create_route53_alias() {
    local hostname="$1"
    local alb_dns="$2"
    local comment="$3"

    # Determine the ALB canonical hosted zone ID
    local alb_hosted_zone_id
    alb_hosted_zone_id="$(aws elbv2 describe-load-balancers \
        --region "${AWS_REGION}" \
        --query "LoadBalancers[?DNSName=='${alb_dns}'].CanonicalHostedZoneId | [0]" \
        --output text 2>/dev/null || true)"

    if [[ -z "${alb_hosted_zone_id}" || "${alb_hosted_zone_id}" == "None" ]]; then
        log_warn "Could not resolve ALB hosted zone ID; using default us-east-1 zone"
        alb_hosted_zone_id="Z35SXDOTRQ7X7K"
    fi

    log_info "Creating Route53 alias: ${hostname} -> ${alb_dns}"

    local change_batch
    change_batch=$(cat <<EOF
{
  "Comment": "${comment}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${hostname}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${alb_hosted_zone_id}",
          "DNSName": "dualstack.${alb_dns}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
    )

    aws route53 change-resource-record-sets \
        --hosted-zone-id "${HOSTED_ZONE_ID}" \
        --change-batch "${change_batch}" \
        --region "${AWS_REGION}"

    log_success "Route53 record created: ${hostname}"
}

create_route53_alias "${OSMO_HOSTNAME}" "${OSMO_ALB_DNS}" \
    "OSMO API ALB alias record managed by Phase 05 deploy"

create_route53_alias "${RAY_DASHBOARD_HOSTNAME}" "${RAY_ALB_DNS}" \
    "Ray Dashboard ALB alias record managed by Phase 05 deploy"

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "OSMO Controller deployment complete"
log_info "OSMO API:      https://${OSMO_HOSTNAME}"
log_info "Ray Dashboard: https://${RAY_DASHBOARD_HOSTNAME}"
