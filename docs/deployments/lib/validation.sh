#!/usr/bin/env bash
################################################################################
# validation.sh - Infrastructure validation functions
#
# Provides:
#   AWS:  validate_vpc, validate_subnet, validate_security_group,
#         validate_vpc_endpoint, validate_hosted_zone, validate_dns_resolution
#   K8s:  validate_k8s_resource, validate_k8s_ready
#   Net:  validate_url, validate_dns
#   Output: print_checklist
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/validation.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------

_VALIDATION_PASS=0
_VALIDATION_FAIL=0

# Array-based results for print_checklist
declare -ga VALIDATION_RESULTS=()

# Print a validation result line and update counters.
_validation_result() {
    local status="$1"
    local message="$2"

    if [[ "$status" == "PASS" ]]; then
        printf "  ${_CLR_GREEN}[PASS]${_CLR_RESET} %s\n" "$message" >&2
        ((_VALIDATION_PASS++)) || true
        VALIDATION_RESULTS+=("PASS|${message}|")
    else
        printf "  ${_CLR_RED}[FAIL]${_CLR_RESET} %s\n" "$message" >&2
        ((_VALIDATION_FAIL++)) || true
        VALIDATION_RESULTS+=("FAIL|${message}|")
    fi
}

# Print summary and return with appropriate code.
validation_summary() {
    local total=$((_VALIDATION_PASS + _VALIDATION_FAIL))
    echo "" >&2
    log_info "Validation Summary: ${_VALIDATION_PASS}/${total} checks passed"

    if [[ $_VALIDATION_FAIL -gt 0 ]]; then
        log_error "${_VALIDATION_FAIL} check(s) failed."
        return 1
    fi

    log_success "All validation checks passed."
    return 0
}

# Reset counters
reset_validation() {
    _VALIDATION_PASS=0
    _VALIDATION_FAIL=0
    VALIDATION_RESULTS=()
}

# ===========================================================================
# AWS Resource Validators
# ===========================================================================

# Validate that a VPC exists and has the expected CIDR.
#
# Usage: validate_vpc <vpc_id> [expected_cidr]
validate_vpc() {
    local vpc_id="$1"
    local expected_cidr="${2:-}"

    local vpc_json
    if ! vpc_json="$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --output json 2>&1)"; then
        _validation_result "FAIL" "VPC ${vpc_id} does not exist or is inaccessible"
        return 1
    fi

    local state cidr
    state="$(echo "$vpc_json" | jq -r '.Vpcs[0].State')"
    cidr="$(echo "$vpc_json" | jq -r '.Vpcs[0].CidrBlock')"

    if [[ "$state" != "available" ]]; then
        _validation_result "FAIL" "VPC ${vpc_id} state is '${state}' (expected 'available')"
        return 1
    fi

    _validation_result "PASS" "VPC ${vpc_id} exists (state=available, cidr=${cidr})"

    if [[ -n "$expected_cidr" && "$cidr" != "$expected_cidr" ]]; then
        _validation_result "FAIL" "VPC CIDR mismatch: got ${cidr}, expected ${expected_cidr}"
        return 1
    fi

    return 0
}

# Validate that a subnet exists in the given VPC.
#
# Usage: validate_subnet <subnet_id> <vpc_id> [expected_cidr]
validate_subnet() {
    local subnet_id="$1"
    local vpc_id="$2"
    local expected_cidr="${3:-}"

    local subnet_json
    if ! subnet_json="$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --output json 2>&1)"; then
        _validation_result "FAIL" "Subnet ${subnet_id} does not exist"
        return 1
    fi

    local actual_vpc cidr az
    actual_vpc="$(echo "$subnet_json" | jq -r '.Subnets[0].VpcId')"
    cidr="$(echo "$subnet_json" | jq -r '.Subnets[0].CidrBlock')"
    az="$(echo "$subnet_json" | jq -r '.Subnets[0].AvailabilityZone')"

    if [[ "$actual_vpc" != "$vpc_id" ]]; then
        _validation_result "FAIL" "Subnet ${subnet_id} is in VPC ${actual_vpc}, expected ${vpc_id}"
        return 1
    fi

    _validation_result "PASS" "Subnet ${subnet_id} exists (cidr=${cidr}, az=${az})"

    if [[ -n "$expected_cidr" && "$cidr" != "$expected_cidr" ]]; then
        _validation_result "FAIL" "Subnet CIDR mismatch: got ${cidr}, expected ${expected_cidr}"
        return 1
    fi

    return 0
}

# Validate that a security group exists in the given VPC.
#
# Usage: validate_security_group <sg_id> <vpc_id>
validate_security_group() {
    local sg_id="$1"
    local vpc_id="$2"

    local sg_json
    if ! sg_json="$(aws ec2 describe-security-groups --group-ids "$sg_id" --output json 2>&1)"; then
        _validation_result "FAIL" "Security group ${sg_id} does not exist"
        return 1
    fi

    local actual_vpc name
    actual_vpc="$(echo "$sg_json" | jq -r '.SecurityGroups[0].VpcId')"
    name="$(echo "$sg_json" | jq -r '.SecurityGroups[0].GroupName')"

    if [[ "$actual_vpc" != "$vpc_id" ]]; then
        _validation_result "FAIL" "Security group ${sg_id} is in VPC ${actual_vpc}, expected ${vpc_id}"
        return 1
    fi

    _validation_result "PASS" "Security group ${sg_id} exists (name=${name})"
    return 0
}

# Validate that a VPC endpoint exists and is available.
#
# Usage: validate_vpc_endpoint <endpoint_id>
validate_vpc_endpoint() {
    local endpoint_id="$1"

    local ep_json
    if ! ep_json="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$endpoint_id" --output json 2>&1)"; then
        _validation_result "FAIL" "VPC endpoint ${endpoint_id} does not exist"
        return 1
    fi

    local state service
    state="$(echo "$ep_json" | jq -r '.VpcEndpoints[0].State')"
    service="$(echo "$ep_json" | jq -r '.VpcEndpoints[0].ServiceName')"

    if [[ "$state" != "available" ]]; then
        _validation_result "FAIL" "VPC endpoint ${endpoint_id} state is '${state}' (expected 'available')"
        return 1
    fi

    _validation_result "PASS" "VPC endpoint ${endpoint_id} available (service=${service})"
    return 0
}

# Validate that a Route 53 hosted zone exists.
#
# Usage: validate_hosted_zone <zone_id> [expected_name]
validate_hosted_zone() {
    local zone_id="$1"
    local expected_name="${2:-}"

    local zone_json
    if ! zone_json="$(aws route53 get-hosted-zone --id "$zone_id" --output json 2>&1)"; then
        _validation_result "FAIL" "Hosted zone ${zone_id} does not exist"
        return 1
    fi

    local name is_private
    name="$(echo "$zone_json" | jq -r '.HostedZone.Name')"
    is_private="$(echo "$zone_json" | jq -r '.HostedZone.Config.PrivateZone')"

    if [[ "$is_private" != "true" ]]; then
        _validation_result "FAIL" "Hosted zone ${zone_id} is not private"
        return 1
    fi

    _validation_result "PASS" "Hosted zone ${zone_id} exists (name=${name}, private=true)"

    if [[ -n "$expected_name" && "$name" != "${expected_name}." ]]; then
        _validation_result "FAIL" "Zone name mismatch: got ${name}, expected ${expected_name}."
        return 1
    fi

    return 0
}

# Validate that DNS resolution works for a given name within the VPC.
#
# Usage: validate_dns_resolution <zone_id> <domain>
validate_dns_resolution() {
    local zone_id="$1"
    local domain="$2"

    local soa_json
    if ! soa_json="$(aws route53 test-dns-answer \
        --hosted-zone-id "$zone_id" \
        --record-name "$domain" \
        --record-type SOA \
        --output json 2>&1)"; then
        _validation_result "FAIL" "DNS resolution test failed for ${domain}"
        return 1
    fi

    local response_code
    response_code="$(echo "$soa_json" | jq -r '.ResponseCode')"

    if [[ "$response_code" == "NOERROR" ]]; then
        _validation_result "PASS" "DNS resolution working for ${domain} (SOA response=NOERROR)"
        return 0
    else
        _validation_result "FAIL" "DNS resolution returned ${response_code} for ${domain}"
        return 1
    fi
}

# ===========================================================================
# URL / Network Validators
# ===========================================================================

# ---------------------------------------------------------------------------
# validate_url - Validate a URL responds with expected HTTP status
# Usage: validate_url "https://mlflow.isaac-lab.internal/health" 200
#        validate_url "https://grafana.isaac-lab.internal/api/health" 200 10
# ---------------------------------------------------------------------------
validate_url() {
    local url="${1:?url required}"
    local expected_status="${2:-200}"
    local timeout="${3:-10}"

    log_info "Validating URL: ${url} (expect ${expected_status})"

    local actual_status
    actual_status="$(curl -so /dev/null -w '%{http_code}' \
        --connect-timeout "${timeout}" \
        --max-time $(( timeout * 3 )) \
        -k "${url}" 2>/dev/null)" || actual_status="000"

    if [[ "${actual_status}" == "${expected_status}" ]]; then
        _validation_result "PASS" "URL ${url} -> HTTP ${actual_status}"
        return 0
    else
        _validation_result "FAIL" "URL ${url} -> HTTP ${actual_status} (expected ${expected_status})"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_dns - Validate DNS resolution for a hostname
# Usage: validate_dns "mlflow.internal"
#        validate_dns "keycloak.internal" "10.100.2.50"
# ---------------------------------------------------------------------------
validate_dns() {
    local hostname="${1:?hostname required}"
    local expected_ip="${2:-}"

    log_info "Validating DNS: ${hostname}"

    local resolved_ips=""

    # Try dig first, fall back to nslookup, then getent
    if command -v dig &>/dev/null; then
        resolved_ips="$(dig +short "${hostname}" A 2>/dev/null | grep -E '^[0-9]+\.' | head -5)"
    elif command -v nslookup &>/dev/null; then
        resolved_ips="$(nslookup "${hostname}" 2>/dev/null | \
            grep -A5 'Name:' | grep 'Address:' | awk '{print $2}' | head -5)"
    elif command -v getent &>/dev/null; then
        resolved_ips="$(getent hosts "${hostname}" 2>/dev/null | awk '{print $1}' | head -5)"
    else
        _validation_result "FAIL" "DNS ${hostname} - no resolution tool available"
        return 1
    fi

    if [[ -z "${resolved_ips}" ]]; then
        _validation_result "FAIL" "DNS ${hostname} - no records found"
        return 1
    fi

    if [[ -n "${expected_ip}" ]]; then
        if echo "${resolved_ips}" | grep -q "${expected_ip}"; then
            _validation_result "PASS" "DNS ${hostname} -> ${resolved_ips} (matches ${expected_ip})"
            return 0
        else
            _validation_result "FAIL" "DNS ${hostname} -> ${resolved_ips} (expected ${expected_ip})"
            return 1
        fi
    fi

    _validation_result "PASS" "DNS ${hostname} -> ${resolved_ips}"
    return 0
}

# ===========================================================================
# Kubernetes Validators
# ===========================================================================

# ---------------------------------------------------------------------------
# validate_k8s_resource - Validate a Kubernetes resource exists
# Usage: validate_k8s_resource "deployment" "mlflow" "mlflow"
# ---------------------------------------------------------------------------
validate_k8s_resource() {
    local resource_type="${1:?resource type required}"
    local name="${2:?resource name required}"
    local namespace="${3:?namespace required}"

    if kubectl get "${resource_type}" "${name}" --namespace "${namespace}" &>/dev/null; then
        _validation_result "PASS" "K8s ${resource_type}/${name} exists in ${namespace}"
        return 0
    else
        _validation_result "FAIL" "K8s ${resource_type}/${name} not found in ${namespace}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_k8s_ready - Validate a Kubernetes resource has Ready condition
# Usage: validate_k8s_ready "deployment" "mlflow" "mlflow"
#        validate_k8s_ready "statefulset" "clickhouse" "logging"
# ---------------------------------------------------------------------------
validate_k8s_ready() {
    local resource_type="${1:?resource type required}"
    local name="${2:?resource name required}"
    local namespace="${3:?namespace required}"

    # First check existence
    if ! kubectl get "${resource_type}" "${name}" --namespace "${namespace}" &>/dev/null; then
        _validation_result "FAIL" "K8s Ready ${resource_type}/${name} - resource not found in ${namespace}"
        return 1
    fi

    local is_ready=false

    case "${resource_type}" in
        deployment)
            local desired available
            desired="$(kubectl get deployment "${name}" -n "${namespace}" \
                -o jsonpath='{.spec.replicas}' 2>/dev/null)"
            available="$(kubectl get deployment "${name}" -n "${namespace}" \
                -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
            if [[ "${desired}" == "${available}" ]] && [[ -n "${available}" ]] && (( available > 0 )); then
                is_ready=true
            fi
            ;;
        statefulset)
            local desired ready
            desired="$(kubectl get statefulset "${name}" -n "${namespace}" \
                -o jsonpath='{.spec.replicas}' 2>/dev/null)"
            ready="$(kubectl get statefulset "${name}" -n "${namespace}" \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
            if [[ "${desired}" == "${ready}" ]] && [[ -n "${ready}" ]] && (( ready > 0 )); then
                is_ready=true
            fi
            ;;
        daemonset)
            local desired ready
            desired="$(kubectl get daemonset "${name}" -n "${namespace}" \
                -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
            ready="$(kubectl get daemonset "${name}" -n "${namespace}" \
                -o jsonpath='{.status.numberReady}' 2>/dev/null)"
            if [[ "${desired}" == "${ready}" ]] && [[ -n "${ready}" ]] && (( ready > 0 )); then
                is_ready=true
            fi
            ;;
        pod)
            local conditions
            conditions="$(kubectl get pod "${name}" -n "${namespace}" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
            if [[ "${conditions}" == "True" ]]; then
                is_ready=true
            fi
            ;;
        *)
            local conditions
            conditions="$(kubectl get "${resource_type}" "${name}" -n "${namespace}" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
            if [[ "${conditions}" == "True" ]]; then
                is_ready=true
            fi
            ;;
    esac

    if ${is_ready}; then
        _validation_result "PASS" "K8s ${resource_type}/${name} is Ready in ${namespace}"
        return 0
    else
        _validation_result "FAIL" "K8s ${resource_type}/${name} is NOT Ready in ${namespace}"
        return 1
    fi
}

# ===========================================================================
# Formatted Output
# ===========================================================================

# ---------------------------------------------------------------------------
# print_checklist - Print formatted validation results with pass/fail counts
# Usage: print_checklist "Phase 1 Validation"
#        print_checklist "Phase 1 Validation" "${custom_results[@]}"
#
# Each entry format: "PASS|check description|detail" or "FAIL|check description|detail"
# If no array is passed, uses the global VALIDATION_RESULTS.
# ---------------------------------------------------------------------------
print_checklist() {
    local title="${1:?title required}"
    shift
    local results=()

    if (( $# > 0 )); then
        results=("$@")
    else
        results=("${VALIDATION_RESULTS[@]}")
    fi

    local pass_count=0
    local fail_count=0
    local total=${#results[@]}

    echo "" >&2
    echo -e "${_CLR_BOLD}================================================================================" >&2
    echo -e "  ${title}" >&2
    echo -e "================================================================================${_CLR_RESET}" >&2
    echo "" >&2

    for entry in "${results[@]}"; do
        local status check detail
        IFS='|' read -r status check detail <<< "${entry}"

        if [[ "${status}" == "PASS" ]]; then
            echo -e "  ${_CLR_GREEN}[PASS]${_CLR_RESET}  ${check}  ${_CLR_DIM}${detail}${_CLR_RESET}" >&2
            pass_count=$(( pass_count + 1 ))
        else
            echo -e "  ${_CLR_RED}[FAIL]${_CLR_RESET}  ${check}  ${_CLR_DIM}${detail}${_CLR_RESET}" >&2
            fail_count=$(( fail_count + 1 ))
        fi
    done

    echo "" >&2
    echo -e "  ${_CLR_BOLD}Results: ${pass_count}/${total} passed, ${fail_count} failed${_CLR_RESET}" >&2

    if (( fail_count > 0 )); then
        echo -e "  ${_CLR_RED}${_CLR_BOLD}VALIDATION FAILED${_CLR_RESET}" >&2
    else
        echo -e "  ${_CLR_GREEN}${_CLR_BOLD}ALL CHECKS PASSED${_CLR_RESET}" >&2
    fi

    echo -e "${_CLR_BOLD}================================================================================${_CLR_RESET}" >&2
    echo "" >&2

    (( fail_count == 0 ))
}
