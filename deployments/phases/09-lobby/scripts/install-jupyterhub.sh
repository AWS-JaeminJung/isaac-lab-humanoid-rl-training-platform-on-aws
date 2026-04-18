#!/usr/bin/env bash
################################################################################
# install-jupyterhub.sh
#
# Deploys JupyterHub via the official Helm chart with:
#   - Keycloak OIDC authentication
#   - Custom notebook image from ECR
#   - Internal ALB Ingress with ACM TLS
#   - Route53 alias record pointing to the ALB
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
MANIFESTS_DIR="${PHASE_DIR}/manifests"
CONFIG_DIR="$(cd "${PHASE_DIR}/../../../config/helm" && pwd)"

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

JUPYTERHUB_NAMESPACE="$(get_tf_output jupyterhub_namespace)"
JUPYTERHUB_HOSTNAME="$(get_tf_output jupyterhub_hostname)"
ACM_CERT_ARN="$(get_tf_output acm_certificate_arn)"
HOSTED_ZONE_ID="$(get_tf_output hosted_zone_id)"
ECR_REPO_URL="$(get_tf_output ecr_repository_url)"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Derive the domain from the hostname (strip the "jupyter." prefix)
DOMAIN="${JUPYTERHUB_HOSTNAME#jupyter.}"

log_info "Namespace:  ${JUPYTERHUB_NAMESPACE}"
log_info "Hostname:   ${JUPYTERHUB_HOSTNAME}"
log_info "Domain:     ${DOMAIN}"
log_info "ECR URL:    ${ECR_REPO_URL}"

# ===========================================================================
# 1. Add JupyterHub Helm Repository
# ===========================================================================

step_start "Add JupyterHub Helm repo"
helm_repo_add "jupyterhub" "https://hub.jupyter.org/helm-chart/"
step_end

# ===========================================================================
# 2. Retrieve OIDC Client Secret from ExternalSecret
# ===========================================================================

step_start "Retrieve OIDC client secret"

MAX_RETRIES=12
RETRY_INTERVAL=10
RETRY_COUNT=0

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    OIDC_CLIENT_SECRET="$(kubectl get secret jupyterhub-oidc-credentials \
        -n "${JUPYTERHUB_NAMESPACE}" \
        -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"

    if [[ -n "${OIDC_CLIENT_SECRET}" && "${OIDC_CLIENT_SECRET}" != "POPULATED_BY_KEYCLOAK_PHASE04" ]]; then
        log_success "OIDC client secret retrieved from ExternalSecret"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
        die "OIDC client secret not available. Ensure the secret is populated in Secrets Manager."
    fi

    log_info "Waiting for jupyterhub-oidc-credentials secret (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep "${RETRY_INTERVAL}"
done

step_end

# ===========================================================================
# 3. Install JupyterHub via Helm
# ===========================================================================

step_start "Install JupyterHub Helm chart"

VALUES_FILE="${CONFIG_DIR}/jupyterhub-values.yaml"

if [[ ! -f "${VALUES_FILE}" ]]; then
    die "Helm values file not found: ${VALUES_FILE}"
fi

KEYCLOAK_BASE="https://keycloak.${DOMAIN}/realms/isaac-lab-production/protocol/openid-connect"

helm_install_or_upgrade "jupyterhub" \
    "jupyterhub/jupyterhub" \
    "${JUPYTERHUB_NAMESPACE}" \
    "${VALUES_FILE}" \
    --version "3.3.8" \
    --set "hub.config.GenericOAuthenticator.client_secret=${OIDC_CLIENT_SECRET}" \
    --set "hub.config.GenericOAuthenticator.oauth_callback_url=https://${JUPYTERHUB_HOSTNAME}/hub/oauth_callback" \
    --set "hub.config.GenericOAuthenticator.authorize_url=${KEYCLOAK_BASE}/auth" \
    --set "hub.config.GenericOAuthenticator.token_url=${KEYCLOAK_BASE}/token" \
    --set "hub.config.GenericOAuthenticator.userdata_url=${KEYCLOAK_BASE}/userinfo" \
    --set "singleuser.image.name=${ECR_REPO_URL}/jupyterhub-notebook" \
    --set "singleuser.image.tag=v1.0.0" \
    --timeout 10m

step_end

# ===========================================================================
# 4. Wait for Hub and Proxy Pods
# ===========================================================================

step_start "Wait for JupyterHub pods"

MAX_WAIT=300
log_info "Waiting up to ${MAX_WAIT}s for Hub Deployment..."

if kubectl rollout status deployment/hub \
    -n "${JUPYTERHUB_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "JupyterHub Hub is ready"
else
    die "JupyterHub Hub did not become ready within ${MAX_WAIT}s"
fi

log_info "Waiting up to ${MAX_WAIT}s for Proxy Deployment..."

if kubectl rollout status deployment/proxy \
    -n "${JUPYTERHUB_NAMESPACE}" \
    --timeout="${MAX_WAIT}s"; then
    log_success "JupyterHub Proxy is ready"
else
    die "JupyterHub Proxy did not become ready within ${MAX_WAIT}s"
fi

step_end

# ===========================================================================
# 5. Apply JupyterHub Ingress Manifest
# ===========================================================================

step_start "Apply JupyterHub Ingress"

export ACM_CERT_ARN
export DOMAIN
envsubst < "${MANIFESTS_DIR}/jupyterhub-ingress.yaml" | kubectl apply -f -

log_info "Ingress applied, waiting for ALB provisioning..."
step_end

# ===========================================================================
# 6. Wait for ALB to be Provisioned
# ===========================================================================

step_start "Wait for ALB"

ALB_DNS_NAME=""
MAX_WAIT=300
ELAPSED=0
POLL_INTERVAL=10

while [[ -z "${ALB_DNS_NAME}" && ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    ALB_DNS_NAME="$(kubectl get ingress jupyterhub \
        -n "${JUPYTERHUB_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [[ -z "${ALB_DNS_NAME}" ]]; then
        log_info "ALB not yet provisioned (${ELAPSED}s/${MAX_WAIT}s)..."
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    fi
done

if [[ -z "${ALB_DNS_NAME}" ]]; then
    die "ALB was not provisioned within ${MAX_WAIT}s. Check the ALB controller logs."
fi

log_success "ALB provisioned: ${ALB_DNS_NAME}"
step_end

# ===========================================================================
# 7. Create Route53 Alias Record
# ===========================================================================

step_start "Create Route53 record"

# Determine the ALB canonical hosted zone ID
ALB_HOSTED_ZONE_ID="$(aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[?DNSName=='${ALB_DNS_NAME}'].CanonicalHostedZoneId | [0]" \
    --output text 2>/dev/null || true)"

if [[ -z "${ALB_HOSTED_ZONE_ID}" || "${ALB_HOSTED_ZONE_ID}" == "None" ]]; then
    log_warn "Could not resolve ALB hosted zone ID; using default us-east-1 zone"
    ALB_HOSTED_ZONE_ID="Z35SXDOTRQ7X7K"
fi

log_info "Creating Route53 alias: ${JUPYTERHUB_HOSTNAME} -> ${ALB_DNS_NAME}"

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "JupyterHub ALB alias record managed by Phase 09 deploy",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${JUPYTERHUB_HOSTNAME}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_HOSTED_ZONE_ID}",
          "DNSName": "dualstack.${ALB_DNS_NAME}",
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
    --change-batch "${CHANGE_BATCH}" \
    --region "${AWS_REGION}"

log_success "Route53 record created: ${JUPYTERHUB_HOSTNAME}"
step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "JupyterHub deployment complete"
log_info "URL:       https://${JUPYTERHUB_HOSTNAME}"
log_info "Hub API:   https://${JUPYTERHUB_HOSTNAME}/hub/api"
log_info "OIDC:      Keycloak (${DOMAIN})"
