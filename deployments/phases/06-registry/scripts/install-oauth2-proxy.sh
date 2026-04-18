#!/usr/bin/env bash
################################################################################
# install-oauth2-proxy.sh
#
# Deploys OAuth2 Proxy in front of MLflow for Keycloak OIDC authentication:
#   - Installs OAuth2 Proxy via Helm (oauth2-proxy/oauth2-proxy chart)
#   - Configures OIDC provider pointing to Keycloak isaac-lab-production realm
#   - Upstream target: MLflow ClusterIP service on port 5000
#   - Reads OIDC client secret from the ExternalSecret-synced K8s secret
#   - Applies Ingress manifest (mlflow-ingress.yaml) pointing to oauth2-proxy
#   - Creates Route53 alias record for mlflow.${domain}
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
MANIFESTS_DIR="${PHASE_DIR}/manifests"

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

MLFLOW_NAMESPACE="$(get_tf_output mlflow_namespace)"
MLFLOW_HOSTNAME="$(get_tf_output mlflow_hostname)"
ACM_CERT_ARN="$(get_tf_output acm_certificate_arn)"
HOSTED_ZONE_ID="$(get_tf_output hosted_zone_id)"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Derive domain from mlflow hostname (strip "mlflow." prefix)
DOMAIN="${MLFLOW_HOSTNAME#mlflow.}"

# Keycloak OIDC issuer URL
OIDC_ISSUER_URL="https://keycloak.${DOMAIN}/realms/isaac-lab-production"

log_info "Namespace:    ${MLFLOW_NAMESPACE}"
log_info "Hostname:     ${MLFLOW_HOSTNAME}"
log_info "OIDC Issuer:  ${OIDC_ISSUER_URL}"

# ---------------------------------------------------------------------------
# Retrieve OIDC client secret from Kubernetes secret (synced by ExternalSecret)
# ---------------------------------------------------------------------------

step_start "Retrieve OIDC client secret"

OIDC_CLIENT_SECRET="$(kubectl get secret mlflow-oauth2-proxy \
    -n "${MLFLOW_NAMESPACE}" \
    -o jsonpath='{.data.client-secret}' | base64 -d)"

if [[ -z "${OIDC_CLIENT_SECRET}" || "${OIDC_CLIENT_SECRET}" == "POPULATED_BY_KEYCLOAK_PHASE04" ]]; then
    log_warn "OIDC client secret not yet populated; ensure Phase 04 configure-realm.sh has run"
    log_warn "Proceeding with placeholder - OAuth2 Proxy will not authenticate until secret is set"
fi

COOKIE_SECRET="$(kubectl get secret mlflow-oauth2-proxy \
    -n "${MLFLOW_NAMESPACE}" \
    -o jsonpath='{.data.cookie-secret}' | base64 -d)"

if [[ -z "${COOKIE_SECRET}" || "${COOKIE_SECRET}" == "CHANGE_ME_BEFORE_DEPLOY" ]]; then
    log_warn "Cookie secret not set; generating a random cookie secret"
    COOKIE_SECRET="$(openssl rand -base64 32 | tr -d '\n')"

    # Update the Secrets Manager secret with the generated cookie secret
    EXISTING_SECRET="$(aws secretsmanager get-secret-value \
        --secret-id "isaac-lab-prod/mlflow-oauth2-proxy" \
        --region "${AWS_REGION}" \
        --query 'SecretString' --output text)"

    UPDATED_SECRET="$(echo "${EXISTING_SECRET}" | jq --arg cs "${COOKIE_SECRET}" '.cookie_secret = $cs')"

    aws secretsmanager put-secret-value \
        --secret-id "isaac-lab-prod/mlflow-oauth2-proxy" \
        --secret-string "${UPDATED_SECRET}" \
        --region "${AWS_REGION}"

    log_info "Cookie secret generated and stored in Secrets Manager"
fi

step_end

# ===========================================================================
# 1. Add OAuth2 Proxy Helm Repository
# ===========================================================================

step_start "Add OAuth2 Proxy Helm repo"
helm_repo_add "oauth2-proxy" "https://oauth2-proxy.github.io/manifests"
step_end

# ===========================================================================
# 2. Install OAuth2 Proxy via Helm
# ===========================================================================

step_start "Install OAuth2 Proxy Helm chart"

helm_install_or_upgrade "mlflow-oauth2-proxy" \
    "oauth2-proxy/oauth2-proxy" \
    "${MLFLOW_NAMESPACE}" \
    "" \
    --version "7.8.1" \
    --set "config.clientID=mlflow" \
    --set "config.clientSecret=${OIDC_CLIENT_SECRET}" \
    --set "config.cookieSecret=${COOKIE_SECRET}" \
    --set "extraArgs.provider=oidc" \
    --set "extraArgs.oidc-issuer-url=${OIDC_ISSUER_URL}" \
    --set "extraArgs.upstream=http://mlflow.mlflow.svc.cluster.local:5000" \
    --set "extraArgs.http-address=0.0.0.0:4180" \
    --set "extraArgs.email-domain=*" \
    --set "extraArgs.pass-access-token=true" \
    --set "extraArgs.set-xauthrequest=true" \
    --set "extraArgs.pass-authorization-header=true" \
    --set "extraArgs.skip-provider-button=true" \
    --set "extraArgs.cookie-secure=true" \
    --set "extraArgs.cookie-samesite=lax" \
    --set "extraArgs.redirect-url=https://${MLFLOW_HOSTNAME}/oauth2/callback" \
    --set "service.portNumber=4180" \
    --set "nodeSelector.node-type=management" \
    --set "replicaCount=1" \
    --set "resources.requests.cpu=100m" \
    --set "resources.requests.memory=128Mi" \
    --set "resources.limits.cpu=200m" \
    --set "resources.limits.memory=256Mi"

step_end

# ===========================================================================
# 3. Apply MLflow Ingress Manifest
# ===========================================================================

step_start "Apply MLflow Ingress"

export ACM_CERT_ARN
export DOMAIN
envsubst < "${MANIFESTS_DIR}/mlflow-ingress.yaml" | kubectl apply -f -

log_info "Ingress applied, waiting for ALB provisioning..."
step_end

# ===========================================================================
# 4. Wait for ALB to be Provisioned
# ===========================================================================

step_start "Wait for ALB"

ALB_DNS_NAME=""
MAX_WAIT=300
ELAPSED=0
POLL_INTERVAL=10

while [[ -z "${ALB_DNS_NAME}" && ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    ALB_DNS_NAME="$(kubectl get ingress mlflow \
        -n "${MLFLOW_NAMESPACE}" \
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
# 5. Create Route53 Alias Record
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

log_info "Creating Route53 alias: ${MLFLOW_HOSTNAME} -> ${ALB_DNS_NAME}"

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "MLflow ALB alias record managed by Phase 06 deploy",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${MLFLOW_HOSTNAME}",
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

log_success "Route53 record created: ${MLFLOW_HOSTNAME}"
step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "OAuth2 Proxy deployment complete"
log_info "MLflow URL: https://${MLFLOW_HOSTNAME}"
log_info "OAuth2 callback: https://${MLFLOW_HOSTNAME}/oauth2/callback"
