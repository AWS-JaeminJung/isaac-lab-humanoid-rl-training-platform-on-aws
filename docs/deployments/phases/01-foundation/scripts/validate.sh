#!/usr/bin/env bash
################################################################################
# Phase 01 - Foundation: Validation Script
#
# Validates that all foundation infrastructure resources were created correctly.
# Reads Terraform outputs and verifies each resource via AWS API calls.
#
# Usage: ./scripts/validate.sh
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${PHASE_DIR}/terraform"

# Source shared libraries
LIB_DIR="$(cd "${PHASE_DIR}/../../.." && pwd)/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/validation.sh"

# ------------------------------------------------------------------------------
# Read Terraform outputs
# ------------------------------------------------------------------------------

log_info "Reading Terraform outputs from ${TF_DIR}..."

get_output() {
    terraform -chdir="${TF_DIR}" output -raw "$1" 2>/dev/null || {
        log_error "Failed to read Terraform output: $1"
        return 1
    }
}

VPC_ID="$(get_output vpc_id)"
GPU_SUBNET_ID="$(get_output gpu_subnet_id)"
MGMT_SUBNET_ID="$(get_output management_subnet_id)"
INFRA_SUBNET_ID="$(get_output infrastructure_subnet_id)"
RESERVED_SUBNET_ID="$(get_output reserved_subnet_id)"
SG_GPU_NODE_ID="$(get_output sg_gpu_node_id)"
SG_MGMT_NODE_ID="$(get_output sg_mgmt_node_id)"
SG_ALB_ID="$(get_output sg_alb_id)"
SG_VPCE_ID="$(get_output sg_vpc_endpoint_id)"
SG_STORAGE_ID="$(get_output sg_storage_id)"
HOSTED_ZONE_ID="$(get_output hosted_zone_id)"
S3_ENDPOINT_ID="$(get_output s3_gateway_endpoint_id)"

# Read domain from Terraform variables (default)
DOMAIN="${DOMAIN:-isaac-lab.internal}"

# ------------------------------------------------------------------------------
# Run validations
# ------------------------------------------------------------------------------

log_info "Starting Phase 01 (Foundation) validation..."
echo "" >&2

# --- VPC ---
step_start "VPC"
validate_vpc "${VPC_ID}" "10.100.0.0/21"
step_end 0

# --- Subnets (4) ---
step_start "Subnets"
validate_subnet "${GPU_SUBNET_ID}"      "${VPC_ID}" "10.100.0.0/24"
validate_subnet "${MGMT_SUBNET_ID}"     "${VPC_ID}" "10.100.1.0/24"
validate_subnet "${INFRA_SUBNET_ID}"    "${VPC_ID}" "10.100.2.0/24"
validate_subnet "${RESERVED_SUBNET_ID}" "${VPC_ID}" "10.100.3.0/24"
step_end 0

# --- Security Groups (5) ---
step_start "Security Groups"
validate_security_group "${SG_GPU_NODE_ID}" "${VPC_ID}"
validate_security_group "${SG_MGMT_NODE_ID}" "${VPC_ID}"
validate_security_group "${SG_ALB_ID}" "${VPC_ID}"
validate_security_group "${SG_VPCE_ID}" "${VPC_ID}"
validate_security_group "${SG_STORAGE_ID}" "${VPC_ID}"
step_end 0

# --- VPC Endpoints ---
step_start "VPC Endpoints"

# S3 Gateway Endpoint
validate_vpc_endpoint "${S3_ENDPOINT_ID}"

# Interface Endpoints: check that they exist in the VPC
INTERFACE_ENDPOINTS_JSON="$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-type,Values=Interface" \
    --query 'VpcEndpoints[*].{Id:VpcEndpointId,Service:ServiceName,State:State}' \
    --output json 2>/dev/null)"

INTERFACE_COUNT="$(echo "${INTERFACE_ENDPOINTS_JSON}" | jq length)"

if [[ "${INTERFACE_COUNT}" -ge 17 ]]; then
    _validation_result "PASS" "Found ${INTERFACE_COUNT} interface VPC endpoints (expected >= 17)"
else
    _validation_result "FAIL" "Found ${INTERFACE_COUNT} interface VPC endpoints (expected >= 17)"
fi

# Validate each interface endpoint is in 'available' state
UNAVAILABLE="$(echo "${INTERFACE_ENDPOINTS_JSON}" | jq '[.[] | select(.State != "available")] | length')"
if [[ "${UNAVAILABLE}" -eq 0 ]]; then
    _validation_result "PASS" "All interface endpoints are in 'available' state"
else
    _validation_result "FAIL" "${UNAVAILABLE} interface endpoint(s) not in 'available' state"
fi

step_end 0

# --- Route 53 ---
step_start "Route 53 Private Hosted Zone"
validate_hosted_zone "${HOSTED_ZONE_ID}" "${DOMAIN}"
step_end 0

# --- DNS Resolution ---
step_start "DNS Resolution"
validate_dns_resolution "${HOSTED_ZONE_ID}" "${DOMAIN}"
step_end 0

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

validation_summary
