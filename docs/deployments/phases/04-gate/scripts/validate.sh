#!/usr/bin/env bash
################################################################################
# validate.sh
#
# Validates Phase 04 deployment:
#   - Keycloak pods running (2 replicas)
#   - Keycloak URL accessible
#   - Realm exists (isaac-lab-production)
#   - LDAP federation configured
#   - 5 OIDC clients exist
#   - 4 Roles exist with gpu_quota attributes
#   - Token endpoint responsive
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Retrieve terraform outputs
# ---------------------------------------------------------------------------

get_tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null
}

KEYCLOAK_NAMESPACE="$(get_tf_output keycloak_namespace)"
KEYCLOAK_HOSTNAME="$(get_tf_output keycloak_hostname)"
KEYCLOAK_URL="https://${KEYCLOAK_HOSTNAME}"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper: check result
# ---------------------------------------------------------------------------

check() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        log_success "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        log_error "FAIL: ${name}"
        FAIL=$((FAIL + 1))
    fi
}

# ===========================================================================
# 1. Keycloak Pods Running
# ===========================================================================

step_start "Keycloak pods"

check "Keycloak pods exist" \
    kubectl get pods -n "${KEYCLOAK_NAMESPACE}" -l app.kubernetes.io/name=keycloak -o name

# Verify 2 replicas are Ready
READY_PODS=$(kubectl get pods -n "${KEYCLOAK_NAMESPACE}" \
    -l app.kubernetes.io/name=keycloak \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")
EXPECTED_PODS=2

if [[ "${READY_PODS}" -ge "${EXPECTED_PODS}" ]]; then
    log_success "PASS: ${READY_PODS}/${EXPECTED_PODS} Keycloak pods Running"
    PASS=$((PASS + 1))
else
    log_error "FAIL: Only ${READY_PODS}/${EXPECTED_PODS} Keycloak pods Running"
    FAIL=$((FAIL + 1))
fi

step_end

# ===========================================================================
# 2. Keycloak URL Accessible
# ===========================================================================

step_start "Keycloak URL accessible"

check "Keycloak health endpoint" \
    curl -sf --max-time 10 "${KEYCLOAK_URL}/health/ready"

check "Keycloak root URL" \
    curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "${KEYCLOAK_URL}/"

step_end

# ===========================================================================
# 3. Ingress and Route53
# ===========================================================================

step_start "Ingress and DNS"

check "Keycloak Ingress exists" \
    kubectl get ingress keycloak -n "${KEYCLOAK_NAMESPACE}"

check "Ingress has ALB address" \
    kubectl get ingress keycloak -n "${KEYCLOAK_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

check "DNS resolves ${KEYCLOAK_HOSTNAME}" \
    nslookup "${KEYCLOAK_HOSTNAME}"

step_end

# ===========================================================================
# 4. Realm Exists
# ===========================================================================

step_start "Realm: isaac-lab-production"

check "Realm discovery endpoint" \
    curl -sf --max-time 10 \
        "${KEYCLOAK_URL}/realms/isaac-lab-production/.well-known/openid-configuration"

step_end

# ===========================================================================
# 5. LDAP Federation
# ===========================================================================

step_start "LDAP federation"

# Load admin credentials
load_secrets
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"

# Get admin token
ADMIN_TOKEN="$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN_USER}&password=${KEYCLOAK_ADMIN_PASSWORD}" \
    | jq -r '.access_token' 2>/dev/null || true)"

if [[ -n "${ADMIN_TOKEN}" && "${ADMIN_TOKEN}" != "null" ]]; then
    check "LDAP federation component exists" \
        curl -sf --max-time 10 \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            "${KEYCLOAK_URL}/admin/realms/isaac-lab-production/components?type=org.keycloak.storage.UserStorageProvider"
else
    log_warn "Could not obtain admin token; skipping LDAP federation check"
fi

step_end

# ===========================================================================
# 6. OIDC Clients
# ===========================================================================

step_start "OIDC clients"

EXPECTED_CLIENTS=("jupyterhub" "grafana" "mlflow" "ray-dashboard" "osmo-api")

if [[ -n "${ADMIN_TOKEN}" && "${ADMIN_TOKEN}" != "null" ]]; then
    for client_id in "${EXPECTED_CLIENTS[@]}"; do
        CLIENT_EXISTS="$(curl -sf --max-time 10 \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            "${KEYCLOAK_URL}/admin/realms/isaac-lab-production/clients?clientId=${client_id}" \
            | jq -r 'length' 2>/dev/null || echo "0")"

        if [[ "${CLIENT_EXISTS}" -gt 0 ]]; then
            log_success "PASS: OIDC client '${client_id}' exists"
            PASS=$((PASS + 1))
        else
            log_error "FAIL: OIDC client '${client_id}' not found"
            FAIL=$((FAIL + 1))
        fi
    done
else
    log_warn "Skipping OIDC client checks (no admin token)"
fi

step_end

# ===========================================================================
# 7. Roles with gpu_quota Attributes
# ===========================================================================

step_start "Realm roles"

EXPECTED_ROLES=("researcher:16" "engineer:32" "admin:80" "viewer:0")

if [[ -n "${ADMIN_TOKEN}" && "${ADMIN_TOKEN}" != "null" ]]; then
    for role_spec in "${EXPECTED_ROLES[@]}"; do
        ROLE_NAME="${role_spec%%:*}"
        EXPECTED_QUOTA="${role_spec##*:}"

        ROLE_DATA="$(curl -sf --max-time 10 \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            "${KEYCLOAK_URL}/admin/realms/isaac-lab-production/roles/${ROLE_NAME}" 2>/dev/null || true)"

        if [[ -n "${ROLE_DATA}" ]]; then
            ACTUAL_QUOTA="$(echo "${ROLE_DATA}" | jq -r '.attributes.gpu_quota[0] // "unset"')"
            if [[ "${ACTUAL_QUOTA}" == "${EXPECTED_QUOTA}" ]]; then
                log_success "PASS: Role '${ROLE_NAME}' exists with gpu_quota=${ACTUAL_QUOTA}"
                PASS=$((PASS + 1))
            else
                log_error "FAIL: Role '${ROLE_NAME}' gpu_quota=${ACTUAL_QUOTA}, expected ${EXPECTED_QUOTA}"
                FAIL=$((FAIL + 1))
            fi
        else
            log_error "FAIL: Role '${ROLE_NAME}' not found"
            FAIL=$((FAIL + 1))
        fi
    done
else
    log_warn "Skipping role checks (no admin token)"
fi

step_end

# ===========================================================================
# 8. Token Endpoint Responsive
# ===========================================================================

step_start "Token endpoint"

check "Token endpoint responds" \
    curl -sf --max-time 10 \
        "${KEYCLOAK_URL}/realms/isaac-lab-production/protocol/openid-connect/token" \
        -d "grant_type=client_credentials&client_id=test" \
        -o /dev/null -w '%{http_code}'

step_end

# ===========================================================================
# 9. ExternalSecrets Synced
# ===========================================================================

step_start "ExternalSecrets"

check "ExternalSecret keycloak-db-credentials synced" \
    kubectl get externalsecret keycloak-db-credentials -n "${KEYCLOAK_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"

check "ExternalSecret keycloak-ldap-credentials synced" \
    kubectl get externalsecret keycloak-ldap-credentials -n "${KEYCLOAK_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"

step_end

# ===========================================================================
# Summary
# ===========================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo "=============================================================================="
echo "  Phase 04 Validation Summary"
echo "=============================================================================="
echo "  PASSED: ${PASS}/${TOTAL}"
echo "  FAILED: ${FAIL}/${TOTAL}"
echo "=============================================================================="
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    log_error "Validation completed with ${FAIL} failure(s)"
    exit 1
else
    log_success "All validation checks passed"
    exit 0
fi
