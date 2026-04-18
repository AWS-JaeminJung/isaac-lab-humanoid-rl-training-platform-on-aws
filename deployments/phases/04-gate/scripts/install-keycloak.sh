#!/usr/bin/env bash
################################################################################
# install-keycloak.sh
#
# Deploys Keycloak via the Bitnami Helm chart with:
#   - 2 replicas on management nodes
#   - External PostgreSQL (RDS) backend
#   - DB credentials sourced from ExternalSecret
#   - Production mode (HTTPS proxy headers)
#   - Internal ALB Ingress with ACM TLS
#   - Route53 alias record pointing to the ALB
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

KEYCLOAK_NAMESPACE="$(get_tf_output keycloak_namespace)"
KEYCLOAK_HOSTNAME="$(get_tf_output keycloak_hostname)"
RDS_ENDPOINT="$(get_tf_output rds_endpoint)"
RDS_PORT="$(get_tf_output rds_port)"
ACM_CERT_ARN="$(get_tf_output acm_certificate_arn)"
HOSTED_ZONE_ID="$(get_tf_output hosted_zone_id)"
AWS_REGION="${AWS_REGION:-us-east-1}"

log_info "Namespace:  ${KEYCLOAK_NAMESPACE}"
log_info "Hostname:   ${KEYCLOAK_HOSTNAME}"
log_info "RDS:        ${RDS_ENDPOINT}:${RDS_PORT}"

# ---------------------------------------------------------------------------
# Load secrets for initial admin password
# ---------------------------------------------------------------------------

load_secrets

KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
if [[ -z "${KEYCLOAK_ADMIN_PASSWORD}" ]]; then
    log_warn "KEYCLOAK_ADMIN_PASSWORD not set; generating a random password"
    KEYCLOAK_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    log_info "Generated admin password (store this securely)"
fi

# ===========================================================================
# 1. Add Bitnami Helm Repository
# ===========================================================================

step_start "Add Bitnami Helm repo"
helm_repo_add "bitnami" "https://charts.bitnami.com/bitnami"
step_end

# ===========================================================================
# 2. Install Keycloak via Helm
# ===========================================================================

step_start "Install Keycloak Helm chart"

helm_install_or_upgrade "keycloak" \
    "bitnami/keycloak" \
    "${KEYCLOAK_NAMESPACE}" \
    "" \
    --version "24.0.5" \
    --set "replicaCount=2" \
    --set "nodeSelector.node-type=management" \
    --set "production=true" \
    --set "proxy=edge" \
    --set "auth.adminUser=admin" \
    --set "auth.adminPassword=${KEYCLOAK_ADMIN_PASSWORD}" \
    --set "postgresql.enabled=false" \
    --set "externalDatabase.host=${RDS_ENDPOINT}" \
    --set "externalDatabase.port=${RDS_PORT}" \
    --set "externalDatabase.database=keycloak_db" \
    --set "externalDatabase.existingSecret=keycloak-db-credentials" \
    --set "externalDatabase.existingSecretUsernameKey=username" \
    --set "externalDatabase.existingSecretPasswordKey=password" \
    --set "service.type=ClusterIP" \
    --set "service.ports.http=8080" \
    --set "readinessProbe.enabled=true" \
    --set "livenessProbe.enabled=true"

step_end

# ===========================================================================
# 3. Apply Keycloak Ingress Manifest
# ===========================================================================

step_start "Apply Keycloak Ingress"

# Substitute the ACM certificate ARN into the Ingress manifest
export ACM_CERT_ARN
envsubst < "${MANIFESTS_DIR}/keycloak-ingress.yaml" | kubectl apply -f -

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
    ALB_DNS_NAME="$(kubectl get ingress keycloak \
        -n "${KEYCLOAK_NAMESPACE}" \
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

log_info "Creating Route53 alias: ${KEYCLOAK_HOSTNAME} -> ${ALB_DNS_NAME}"

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Keycloak ALB alias record managed by Phase 04 deploy",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${KEYCLOAK_HOSTNAME}",
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

log_success "Route53 record created: ${KEYCLOAK_HOSTNAME}"
step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "Keycloak deployment complete"
log_info "Admin URL: https://${KEYCLOAK_HOSTNAME}/admin"
log_info "Realm URL: https://${KEYCLOAK_HOSTNAME}/realms/isaac-lab-production"
