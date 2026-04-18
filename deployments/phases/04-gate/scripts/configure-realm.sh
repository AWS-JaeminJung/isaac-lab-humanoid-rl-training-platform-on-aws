#!/usr/bin/env bash
################################################################################
# configure-realm.sh
#
# Configures the Keycloak realm, AD LDAP federation, roles, and OIDC clients.
#
#   1. Creates realm: isaac-lab-production
#   2. Configures AD LDAP federation (LDAPS:636, full sync 24h, changed 15min)
#   3. Creates 3 roles: researcher (gpu_quota=4), engineer (gpu_quota=10), viewer
#   4. Creates LDAP group-to-role mapper
#   5. Creates 5 OIDC clients (jupyterhub, grafana, mlflow, ray-dashboard, osmo-api)
#   6. Stores client secrets to AWS Secrets Manager
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
REALM_CONFIG_DIR="${PHASE_DIR}/realm-config"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

KEYCLOAK_HOSTNAME="$(get_tf_output keycloak_hostname)"
KEYCLOAK_URL="https://${KEYCLOAK_HOSTNAME}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# Load secrets for admin credentials
# ---------------------------------------------------------------------------

load_secrets

KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"

# ---------------------------------------------------------------------------
# Helper: get admin access token
# ---------------------------------------------------------------------------

get_admin_token() {
    local token
    token=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=${KEYCLOAK_ADMIN_USER}" \
        -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        | jq -r '.access_token')

    if [[ -z "${token}" || "${token}" == "null" ]]; then
        die "Failed to obtain Keycloak admin token"
    fi
    echo "${token}"
}

# ---------------------------------------------------------------------------
# Helper: Keycloak Admin API call
# ---------------------------------------------------------------------------

kc_api() {
    local method="${1:?method required}"
    local path="${2:?path required}"
    shift 2
    local token
    token="$(get_admin_token)"

    curl -sf -X "${method}" "${KEYCLOAK_URL}/admin${path}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "$@"
}

# ===========================================================================
# 1. Create Realm
# ===========================================================================

step_start "Create realm: isaac-lab-production"

REALM_JSON="$(cat "${REALM_CONFIG_DIR}/realm-export.json")"

# Check if realm already exists
if kc_api GET "/realms/isaac-lab-production" &>/dev/null; then
    log_info "Realm 'isaac-lab-production' already exists, updating..."
    kc_api PUT "/realms/isaac-lab-production" -d "${REALM_JSON}"
else
    log_info "Creating realm 'isaac-lab-production'..."
    kc_api POST "/realms" -d "${REALM_JSON}"
fi

log_success "Realm configured"
step_end

# ===========================================================================
# 2. Configure LDAP Federation
# ===========================================================================

step_start "Configure LDAP federation"

LDAP_CONFIG="$(cat "${REALM_CONFIG_DIR}/ldap-federation.json")"

# Get LDAP bind password from Secrets Manager
LDAP_BIND_PASSWORD="$(aws secretsmanager get-secret-value \
    --secret-id "isaac-lab-prod/keycloak-ldap-credentials" \
    --region "${AWS_REGION}" \
    --query 'SecretString' --output text | jq -r '.bind_password')"

# Inject bind password into LDAP config
LDAP_CONFIG="$(echo "${LDAP_CONFIG}" | jq --arg pw "${LDAP_BIND_PASSWORD}" \
    '.config.bindCredential = [$pw]')"

# Check for existing LDAP federation
EXISTING_LDAP_ID="$(kc_api GET "/realms/isaac-lab-production/components?type=org.keycloak.storage.UserStorageProvider" \
    | jq -r '.[] | select(.name == "corp-active-directory") | .id' 2>/dev/null || true)"

if [[ -n "${EXISTING_LDAP_ID}" ]]; then
    log_info "Updating existing LDAP federation (${EXISTING_LDAP_ID})..."
    kc_api PUT "/realms/isaac-lab-production/components/${EXISTING_LDAP_ID}" \
        -d "${LDAP_CONFIG}"
else
    log_info "Creating LDAP federation..."
    kc_api POST "/realms/isaac-lab-production/components" -d "${LDAP_CONFIG}"
fi

# Get the federation component ID for mapper creation
LDAP_FEDERATION_ID="$(kc_api GET "/realms/isaac-lab-production/components?type=org.keycloak.storage.UserStorageProvider" \
    | jq -r '.[] | select(.name == "corp-active-directory") | .id')"

log_success "LDAP federation configured (ID: ${LDAP_FEDERATION_ID})"
step_end

# ===========================================================================
# 3. Create Realm Roles
# ===========================================================================

step_start "Create realm roles"

ROLE_MAPPINGS="$(cat "${REALM_CONFIG_DIR}/role-mappings.json")"

for role_entry in $(echo "${ROLE_MAPPINGS}" | jq -c '.roles[]'); do
    ROLE_NAME="$(echo "${role_entry}" | jq -r '.name')"
    GPU_QUOTA="$(echo "${role_entry}" | jq -r '.attributes.gpu_quota')"
    ROLE_DESC="$(echo "${role_entry}" | jq -r '.description')"

    # Check if role exists
    if kc_api GET "/realms/isaac-lab-production/roles/${ROLE_NAME}" &>/dev/null; then
        log_info "Role '${ROLE_NAME}' exists, updating attributes..."
        kc_api PUT "/realms/isaac-lab-production/roles/${ROLE_NAME}" \
            -d "{\"name\":\"${ROLE_NAME}\",\"description\":\"${ROLE_DESC}\",\"attributes\":{\"gpu_quota\":[\"${GPU_QUOTA}\"]}}"
    else
        log_info "Creating role '${ROLE_NAME}' (gpu_quota=${GPU_QUOTA})..."
        kc_api POST "/realms/isaac-lab-production/roles" \
            -d "{\"name\":\"${ROLE_NAME}\",\"description\":\"${ROLE_DESC}\",\"attributes\":{\"gpu_quota\":[\"${GPU_QUOTA}\"]}}"
    fi
done

log_success "Realm roles configured"
step_end

# ===========================================================================
# 4. Create LDAP Group-to-Role Mapper
# ===========================================================================

step_start "Create LDAP group mapper"

for role_entry in $(echo "${ROLE_MAPPINGS}" | jq -c '.roles[]'); do
    ROLE_NAME="$(echo "${role_entry}" | jq -r '.name')"
    AD_GROUP="$(echo "${role_entry}" | jq -r '.ad_group')"

    MAPPER_NAME="ad-group-${ROLE_NAME}"

    MAPPER_JSON=$(cat <<EOJSON
{
  "name": "${MAPPER_NAME}",
  "providerId": "role-ldap-mapper",
  "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
  "parentId": "${LDAP_FEDERATION_ID}",
  "config": {
    "roles.dn": ["OU=Groups,DC=corp,DC=internal"],
    "role.name.ldap.attribute": ["cn"],
    "role.object.classes": ["group"],
    "membership.ldap.attribute": ["member"],
    "membership.attribute.type": ["DN"],
    "membership.user.ldap.attribute": ["sAMAccountName"],
    "roles.ldap.filter": ["(cn=${AD_GROUP})"],
    "mode": ["LDAP_ONLY"],
    "user.roles.retrieve.strategy": ["LOAD_ROLES_BY_MEMBER_ATTRIBUTE"],
    "use.realm.roles.mapping": ["true"]
  }
}
EOJSON
)

    # Check if mapper exists
    EXISTING_MAPPER_ID="$(kc_api GET "/realms/isaac-lab-production/components?parent=${LDAP_FEDERATION_ID}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
        | jq -r ".[] | select(.name == \"${MAPPER_NAME}\") | .id" 2>/dev/null || true)"

    if [[ -n "${EXISTING_MAPPER_ID}" ]]; then
        log_info "Updating LDAP mapper '${MAPPER_NAME}'..."
        kc_api PUT "/realms/isaac-lab-production/components/${EXISTING_MAPPER_ID}" \
            -d "${MAPPER_JSON}"
    else
        log_info "Creating LDAP mapper '${MAPPER_NAME}' (AD group: ${AD_GROUP})..."
        kc_api POST "/realms/isaac-lab-production/components" -d "${MAPPER_JSON}"
    fi
done

log_success "LDAP group mappers configured"
step_end

# ===========================================================================
# 5. Create OIDC Clients
# ===========================================================================

step_start "Create OIDC clients"

OIDC_CLIENTS="$(cat "${REALM_CONFIG_DIR}/oidc-clients.json")"

for client_entry in $(echo "${OIDC_CLIENTS}" | jq -c '.clients[]'); do
    CLIENT_ID="$(echo "${client_entry}" | jq -r '.clientId')"
    CLIENT_NAME="$(echo "${client_entry}" | jq -r '.name')"

    # Check if client exists
    EXISTING_CLIENT="$(kc_api GET "/realms/isaac-lab-production/clients?clientId=${CLIENT_ID}" \
        | jq -r '.[0].id // empty' 2>/dev/null || true)"

    if [[ -n "${EXISTING_CLIENT}" ]]; then
        log_info "Client '${CLIENT_ID}' exists (${EXISTING_CLIENT}), updating..."
        kc_api PUT "/realms/isaac-lab-production/clients/${EXISTING_CLIENT}" \
            -d "${client_entry}"
    else
        log_info "Creating client '${CLIENT_ID}'..."
        kc_api POST "/realms/isaac-lab-production/clients" -d "${client_entry}"
    fi

    # Retrieve the client UUID
    CLIENT_UUID="$(kc_api GET "/realms/isaac-lab-production/clients?clientId=${CLIENT_ID}" \
        | jq -r '.[0].id')"

    # Get client secret (skip for bearer-only clients)
    IS_BEARER_ONLY="$(echo "${client_entry}" | jq -r '.bearerOnly // false')"
    if [[ "${IS_BEARER_ONLY}" != "true" ]]; then
        CLIENT_SECRET="$(kc_api GET "/realms/isaac-lab-production/clients/${CLIENT_UUID}/client-secret" \
            | jq -r '.value')"

        # Store client secret in Secrets Manager
        log_info "Storing '${CLIENT_ID}' client secret in Secrets Manager..."
        aws secretsmanager put-secret-value \
            --secret-id "isaac-lab-prod/keycloak-oidc-${CLIENT_ID}" \
            --secret-string "{\"client_id\":\"${CLIENT_ID}\",\"client_secret\":\"${CLIENT_SECRET}\"}" \
            --region "${AWS_REGION}"
    else
        log_info "Skipping secret retrieval for bearer-only client '${CLIENT_ID}'"
    fi
done

log_success "OIDC clients configured"
step_end

# ===========================================================================
# 6. Trigger Initial LDAP Sync
# ===========================================================================

step_start "Trigger LDAP full sync"

kc_api POST "/realms/isaac-lab-production/user-storage/${LDAP_FEDERATION_ID}/sync?action=triggerFullSync" || true

log_success "LDAP full sync triggered"
step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "Keycloak realm configuration complete"
log_info "Realm: isaac-lab-production"
log_info "Roles: researcher (gpu_quota=4), engineer (gpu_quota=10), viewer (gpu_quota=0)"
log_info "Clients: jupyterhub, grafana, mlflow, ray-dashboard, osmo-api"
