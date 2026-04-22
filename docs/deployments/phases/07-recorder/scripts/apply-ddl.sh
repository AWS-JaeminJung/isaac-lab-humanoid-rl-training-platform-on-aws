#!/usr/bin/env bash
################################################################################
# apply-ddl.sh
#
# Applies DDL SQL files from the ddl/ directory to ClickHouse in order:
#   - Reads 001-*, 002-*, 003-* files sorted alphabetically
#   - Executes each via kubectl exec into clickhouse-0 using clickhouse-client
#   - Idempotent: all DDL uses CREATE TABLE IF NOT EXISTS
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PHASE_DIR}/terraform"
DDL_DIR="${PHASE_DIR}/ddl"

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

LOGGING_NAMESPACE="$(get_tf_output logging_namespace)"

log_info "Namespace: ${LOGGING_NAMESPACE}"
log_info "DDL directory: ${DDL_DIR}"

# ===========================================================================
# Apply DDL Files in Order
# ===========================================================================

step_start "Apply DDL schemas to ClickHouse"

DDL_FILES=($(ls -1 "${DDL_DIR}"/*.sql 2>/dev/null | sort))

if [[ ${#DDL_FILES[@]} -eq 0 ]]; then
    log_warn "No DDL files found in ${DDL_DIR}"
    step_end
    exit 0
fi

log_info "Found ${#DDL_FILES[@]} DDL file(s) to apply"

for ddl_file in "${DDL_FILES[@]}"; do
    ddl_name="$(basename "${ddl_file}")"
    log_info "Applying DDL: ${ddl_name}"

    if kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
        clickhouse-client --query "$(cat "${ddl_file}")"; then
        log_success "DDL applied: ${ddl_name}"
    else
        die "Failed to apply DDL: ${ddl_name}"
    fi
done

step_end

# ===========================================================================
# Verify Tables Created
# ===========================================================================

step_start "Verify ClickHouse tables"

TABLES=$(kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
    clickhouse-client --query "SHOW TABLES" 2>/dev/null)

EXPECTED_TABLES=("training_metrics" "training_raw_logs" "training_summary")

for table in "${EXPECTED_TABLES[@]}"; do
    if echo "${TABLES}" | grep -q "${table}"; then
        log_success "Table exists: ${table}"
    else
        die "Table missing after DDL apply: ${table}"
    fi
done

step_end

# ===========================================================================
# Done
# ===========================================================================

log_success "All DDL schemas applied successfully"
log_info "Tables: ${EXPECTED_TABLES[*]}"
