#!/usr/bin/env bash
################################################################################
# record-baseline.sh
#
# Queries ClickHouse for performance metrics from all 4 stages and records
# a performance baseline:
#   - Retrieves metrics for each stage (iterations/sec, mean reward, GPU util)
#   - Records baseline to a JSON file
#   - Prints summary table
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

LOGGING_NAMESPACE="logging"
BASELINE_FILE="${PHASE_DIR}/baseline-$(date +%Y%m%d-%H%M%S).json"

log_info "Recording performance baseline to: ${BASELINE_FILE}"

# ---------------------------------------------------------------------------
# Helper: query ClickHouse
# ---------------------------------------------------------------------------

ch_query() {
    local query="$1"
    kubectl exec -n "${LOGGING_NAMESPACE}" clickhouse-0 -- \
        clickhouse-client --query "${query}" 2>/dev/null || echo ""
}

# ===========================================================================
# 1. Stage 1: Single GPU Metrics
# ===========================================================================

step_start "Collect Stage 1 (single GPU) metrics"

S1_ITERATIONS="$(ch_query "SELECT max(iteration) FROM training_metrics WHERE workflow_id LIKE '%single-gpu%'")"
S1_MEAN_REWARD="$(ch_query "SELECT round(max(mean_reward), 4) FROM training_metrics WHERE workflow_id LIKE '%single-gpu%'")"
S1_DURATION="$(ch_query "SELECT dateDiff('second', min(timestamp), max(timestamp)) FROM training_metrics WHERE workflow_id LIKE '%single-gpu%'")"
S1_IPS="$(ch_query "SELECT round(max(iteration) / nullIf(dateDiff('second', min(timestamp), max(timestamp)), 0), 2) FROM training_metrics WHERE workflow_id LIKE '%single-gpu%'")"

S1_ITERATIONS="$(echo "${S1_ITERATIONS}" | tr -d '[:space:]')"
S1_MEAN_REWARD="$(echo "${S1_MEAN_REWARD}" | tr -d '[:space:]')"
S1_DURATION="$(echo "${S1_DURATION}" | tr -d '[:space:]')"
S1_IPS="$(echo "${S1_IPS}" | tr -d '[:space:]')"

log_info "Stage 1: iterations=${S1_ITERATIONS}, reward=${S1_MEAN_REWARD}, duration=${S1_DURATION}s, iter/s=${S1_IPS}"

step_end

# ===========================================================================
# 2. Stage 2: Multi-GPU Metrics
# ===========================================================================

step_start "Collect Stage 2 (multi-GPU) metrics"

S2_ITERATIONS="$(ch_query "SELECT max(iteration) FROM training_metrics WHERE workflow_id LIKE '%multi-gpu%'")"
S2_MEAN_REWARD="$(ch_query "SELECT round(max(mean_reward), 4) FROM training_metrics WHERE workflow_id LIKE '%multi-gpu%'")"
S2_DURATION="$(ch_query "SELECT dateDiff('second', min(timestamp), max(timestamp)) FROM training_metrics WHERE workflow_id LIKE '%multi-gpu%'")"
S2_IPS="$(ch_query "SELECT round(max(iteration) / nullIf(dateDiff('second', min(timestamp), max(timestamp)), 0), 2) FROM training_metrics WHERE workflow_id LIKE '%multi-gpu%'")"

S2_ITERATIONS="$(echo "${S2_ITERATIONS}" | tr -d '[:space:]')"
S2_MEAN_REWARD="$(echo "${S2_MEAN_REWARD}" | tr -d '[:space:]')"
S2_DURATION="$(echo "${S2_DURATION}" | tr -d '[:space:]')"
S2_IPS="$(echo "${S2_IPS}" | tr -d '[:space:]')"

log_info "Stage 2: iterations=${S2_ITERATIONS}, reward=${S2_MEAN_REWARD}, duration=${S2_DURATION}s, iter/s=${S2_IPS}"

step_end

# ===========================================================================
# 3. Stage 3: Multi-Node Metrics
# ===========================================================================

step_start "Collect Stage 3 (multi-node) metrics"

S3_ITERATIONS="$(ch_query "SELECT max(iteration) FROM training_metrics WHERE workflow_id LIKE '%multi-node%'")"
S3_MEAN_REWARD="$(ch_query "SELECT round(max(mean_reward), 4) FROM training_metrics WHERE workflow_id LIKE '%multi-node%'")"
S3_DURATION="$(ch_query "SELECT dateDiff('second', min(timestamp), max(timestamp)) FROM training_metrics WHERE workflow_id LIKE '%multi-node%'")"
S3_IPS="$(ch_query "SELECT round(max(iteration) / nullIf(dateDiff('second', min(timestamp), max(timestamp)), 0), 2) FROM training_metrics WHERE workflow_id LIKE '%multi-node%'")"

S3_ITERATIONS="$(echo "${S3_ITERATIONS}" | tr -d '[:space:]')"
S3_MEAN_REWARD="$(echo "${S3_MEAN_REWARD}" | tr -d '[:space:]')"
S3_DURATION="$(echo "${S3_DURATION}" | tr -d '[:space:]')"
S3_IPS="$(echo "${S3_IPS}" | tr -d '[:space:]')"

log_info "Stage 3: iterations=${S3_ITERATIONS}, reward=${S3_MEAN_REWARD}, duration=${S3_DURATION}s, iter/s=${S3_IPS}"

step_end

# ===========================================================================
# 4. Stage 4: HPO Metrics
# ===========================================================================

step_start "Collect Stage 4 (HPO) metrics"

S4_TRIALS="$(ch_query "SELECT uniqExact(trial_id) FROM training_metrics WHERE workflow_id LIKE '%hpo%'")"
S4_BEST_REWARD="$(ch_query "SELECT round(max(mean_reward), 4) FROM training_metrics WHERE workflow_id LIKE '%hpo%'")"
S4_TOTAL_ITERATIONS="$(ch_query "SELECT sum(iteration) FROM training_metrics WHERE workflow_id LIKE '%hpo%'")"
S4_DURATION="$(ch_query "SELECT dateDiff('second', min(timestamp), max(timestamp)) FROM training_metrics WHERE workflow_id LIKE '%hpo%'")"

S4_TRIALS="$(echo "${S4_TRIALS}" | tr -d '[:space:]')"
S4_BEST_REWARD="$(echo "${S4_BEST_REWARD}" | tr -d '[:space:]')"
S4_TOTAL_ITERATIONS="$(echo "${S4_TOTAL_ITERATIONS}" | tr -d '[:space:]')"
S4_DURATION="$(echo "${S4_DURATION}" | tr -d '[:space:]')"

log_info "Stage 4: trials=${S4_TRIALS}, best_reward=${S4_BEST_REWARD}, total_iter=${S4_TOTAL_ITERATIONS}, duration=${S4_DURATION}s"

step_end

# ===========================================================================
# 5. Write Baseline JSON
# ===========================================================================

step_start "Write baseline JSON"

cat > "${BASELINE_FILE}" <<BASELINE_JSON
{
  "baseline_version": "1.0.0",
  "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "task": "H1-v0",
  "stages": {
    "stage1_single_gpu": {
      "description": "Single GPU (1x On-Prem GPU)",
      "gpus": 1,
      "max_iterations": ${S1_ITERATIONS:-0},
      "mean_reward": ${S1_MEAN_REWARD:-0},
      "duration_seconds": ${S1_DURATION:-0},
      "iterations_per_second": ${S1_IPS:-0}
    },
    "stage2_multi_gpu": {
      "description": "Multi-GPU (1x g7e.48xlarge, 8 GPUs)",
      "gpus": 8,
      "max_iterations": ${S2_ITERATIONS:-0},
      "mean_reward": ${S2_MEAN_REWARD:-0},
      "duration_seconds": ${S2_DURATION:-0},
      "iterations_per_second": ${S2_IPS:-0}
    },
    "stage3_multi_node": {
      "description": "Multi-Node (2x g7e.48xlarge, 16 GPUs)",
      "gpus": 16,
      "max_iterations": ${S3_ITERATIONS:-0},
      "mean_reward": ${S3_MEAN_REWARD:-0},
      "duration_seconds": ${S3_DURATION:-0},
      "iterations_per_second": ${S3_IPS:-0}
    },
    "stage4_hpo": {
      "description": "HPO with ASHA scheduler",
      "total_trials": ${S4_TRIALS:-0},
      "best_reward": ${S4_BEST_REWARD:-0},
      "total_iterations": ${S4_TOTAL_ITERATIONS:-0},
      "duration_seconds": ${S4_DURATION:-0}
    }
  }
}
BASELINE_JSON

log_success "Baseline written to: ${BASELINE_FILE}"

step_end

# ===========================================================================
# Summary Table
# ===========================================================================

echo ""
echo "=============================================================================="
echo "  Performance Baseline Summary"
echo "=============================================================================="
printf "  %-20s %-8s %-12s %-12s %-12s\n" "Stage" "GPUs" "Iterations" "Reward" "Iter/s"
echo "  --------------------------------------------------------------------------"
printf "  %-20s %-8s %-12s %-12s %-12s\n" "1. Single GPU" "1" "${S1_ITERATIONS:-N/A}" "${S1_MEAN_REWARD:-N/A}" "${S1_IPS:-N/A}"
printf "  %-20s %-8s %-12s %-12s %-12s\n" "2. Multi-GPU" "8" "${S2_ITERATIONS:-N/A}" "${S2_MEAN_REWARD:-N/A}" "${S2_IPS:-N/A}"
printf "  %-20s %-8s %-12s %-12s %-12s\n" "3. Multi-Node" "16" "${S3_ITERATIONS:-N/A}" "${S3_MEAN_REWARD:-N/A}" "${S3_IPS:-N/A}"
printf "  %-20s %-8s %-12s %-12s %-12s\n" "4. HPO" "32max" "${S4_TOTAL_ITERATIONS:-N/A}" "${S4_BEST_REWARD:-N/A}" "-"
echo "=============================================================================="
echo "  HPO Trials: ${S4_TRIALS:-N/A}"
echo "  Baseline file: ${BASELINE_FILE}"
echo "=============================================================================="
echo ""

log_success "Performance baseline recorded successfully"
