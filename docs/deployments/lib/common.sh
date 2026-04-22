#!/usr/bin/env bash
################################################################################
# common.sh - Shared shell functions for Isaac Lab deployment infrastructure
#
# Provides: colored logging, die(), retry() with exponential backoff,
#           phase_start/phase_end with elapsed time, step_start/step_end.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
################################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Directory detection
# ---------------------------------------------------------------------------
# SCRIPT_DIR: the directory of the script that sourced this file
# REPO_ROOT:  the top-level deployments directory
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Color codes (disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly _CLR_RESET='\033[0m'
    readonly _CLR_RED='\033[0;31m'
    readonly _CLR_GREEN='\033[0;32m'
    readonly _CLR_YELLOW='\033[0;33m'
    readonly _CLR_BLUE='\033[0;34m'
    readonly _CLR_CYAN='\033[0;36m'
    readonly _CLR_BOLD='\033[1m'
    readonly _CLR_DIM='\033[2m'
else
    readonly _CLR_RESET=''
    readonly _CLR_RED=''
    readonly _CLR_GREEN=''
    readonly _CLR_YELLOW=''
    readonly _CLR_BLUE=''
    readonly _CLR_CYAN=''
    readonly _CLR_BOLD=''
    readonly _CLR_DIM=''
fi

# ---------------------------------------------------------------------------
# Timestamp helper
# ---------------------------------------------------------------------------
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# ---------------------------------------------------------------------------
# Logging functions
# ---------------------------------------------------------------------------
log_info() {
    echo -e "${_CLR_BLUE}[INFO]${_CLR_RESET}  $(_timestamp)  $*" >&2
}

log_warn() {
    echo -e "${_CLR_YELLOW}[WARN]${_CLR_RESET}  $(_timestamp)  $*" >&2
}

log_error() {
    echo -e "${_CLR_RED}[ERROR]${_CLR_RESET} $(_timestamp)  $*" >&2
}

log_success() {
    echo -e "${_CLR_GREEN}[OK]${_CLR_RESET}    $(_timestamp)  $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${_CLR_DIM}[DEBUG]${_CLR_RESET} $(_timestamp)  $*" >&2
    fi
}

# ---------------------------------------------------------------------------
# die - Print error message and exit with code 1
# Usage: die "something went wrong"
# ---------------------------------------------------------------------------
die() {
    log_error "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# retry - Retry a command with exponential backoff
# Usage: retry <max_attempts> <initial_delay_seconds> <command...>
#
# Example: retry 5 2 curl -sf https://example.com/health
#   Attempt 1: run immediately
#   Attempt 2: wait 2s
#   Attempt 3: wait 4s
#   Attempt 4: wait 8s
#   Attempt 5: wait 16s (then fail)
# ---------------------------------------------------------------------------
retry() {
    local max_attempts="${1:?max_attempts required}"
    local delay="${2:?initial_delay required}"
    shift 2

    local attempt=1
    local exit_code=0

    while (( attempt <= max_attempts )); do
        exit_code=0
        "$@" && return 0 || exit_code=$?

        if (( attempt == max_attempts )); then
            log_error "Command failed after ${max_attempts} attempts: $*"
            return "${exit_code}"
        fi

        log_warn "Attempt ${attempt}/${max_attempts} failed (exit ${exit_code}). Retrying in ${delay}s..."
        sleep "${delay}"
        delay=$(( delay * 2 ))
        attempt=$(( attempt + 1 ))
    done
}

# ---------------------------------------------------------------------------
# Phase tracking - for high-level deployment phases
# ---------------------------------------------------------------------------
declare -g _PHASE_START_TIME=""
declare -g _PHASE_NAME=""

phase_start() {
    _PHASE_NAME="${1:?phase name required}"
    _PHASE_START_TIME="$(date +%s)"
    echo "" >&2
    echo -e "${_CLR_BOLD}${_CLR_CYAN}================================================================================${_CLR_RESET}" >&2
    echo -e "${_CLR_BOLD}${_CLR_CYAN}  PHASE: ${_PHASE_NAME}${_CLR_RESET}" >&2
    echo -e "${_CLR_BOLD}${_CLR_CYAN}  Started: $(_timestamp)${_CLR_RESET}" >&2
    echo -e "${_CLR_BOLD}${_CLR_CYAN}================================================================================${_CLR_RESET}" >&2
    echo "" >&2
}

phase_end() {
    local status="${1:-0}"
    local end_time
    end_time="$(date +%s)"
    local elapsed=$(( end_time - _PHASE_START_TIME ))
    local minutes=$(( elapsed / 60 ))
    local seconds=$(( elapsed % 60 ))

    echo "" >&2
    if [[ "${status}" -eq 0 ]]; then
        echo -e "${_CLR_BOLD}${_CLR_GREEN}================================================================================${_CLR_RESET}" >&2
        echo -e "${_CLR_BOLD}${_CLR_GREEN}  PHASE COMPLETE: ${_PHASE_NAME}${_CLR_RESET}" >&2
    else
        echo -e "${_CLR_BOLD}${_CLR_RED}================================================================================${_CLR_RESET}" >&2
        echo -e "${_CLR_BOLD}${_CLR_RED}  PHASE FAILED: ${_PHASE_NAME}${_CLR_RESET}" >&2
    fi
    echo -e "${_CLR_BOLD}  Elapsed: ${minutes}m ${seconds}s${_CLR_RESET}" >&2
    echo -e "${_CLR_BOLD}================================================================================${_CLR_RESET}" >&2
    echo "" >&2

    _PHASE_NAME=""
    _PHASE_START_TIME=""
    return "${status}"
}

# ---------------------------------------------------------------------------
# Step tracking - for sub-steps within a phase
# ---------------------------------------------------------------------------
declare -g _STEP_START_TIME=""
declare -g _STEP_NAME=""
declare -g _STEP_NUMBER=0

step_start() {
    _STEP_NAME="${1:?step name required}"
    _STEP_NUMBER=$(( _STEP_NUMBER + 1 ))
    _STEP_START_TIME="$(date +%s)"
    echo -e "${_CLR_BOLD}--- Step ${_STEP_NUMBER}: ${_STEP_NAME}${_CLR_RESET}" >&2
}

step_end() {
    local status="${1:-0}"
    local end_time
    end_time="$(date +%s)"
    local elapsed=$(( end_time - _STEP_START_TIME ))

    if [[ "${status}" -eq 0 ]]; then
        echo -e "${_CLR_GREEN}    Step ${_STEP_NUMBER} completed (${elapsed}s)${_CLR_RESET}" >&2
    else
        echo -e "${_CLR_RED}    Step ${_STEP_NUMBER} FAILED (${elapsed}s)${_CLR_RESET}" >&2
    fi

    _STEP_NAME=""
    _STEP_START_TIME=""
    return "${status}"
}

# ---------------------------------------------------------------------------
# Utility: confirm prompt
# Usage: confirm "Are you sure?" || exit 0
# ---------------------------------------------------------------------------
confirm() {
    local prompt="${1:-Continue?}"
    local response
    echo -en "${_CLR_YELLOW}${prompt} [y/N]: ${_CLR_RESET}" >&2
    read -r response
    case "${response}" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Utility: require_env - ensure an environment variable is set
# Usage: require_env AWS_REGION AWS_ACCOUNT_ID
# ---------------------------------------------------------------------------
require_env() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Required environment variables not set: ${missing[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Utility: source a secrets.env file if it exists
# ---------------------------------------------------------------------------
load_secrets() {
    local secrets_file="${1:-${REPO_ROOT}/config/secrets.env}"
    if [[ -f "${secrets_file}" ]]; then
        log_info "Loading secrets from ${secrets_file}"
        set -a
        # shellcheck disable=SC1090
        source "${secrets_file}"
        set +a
    else
        log_warn "Secrets file not found: ${secrets_file}"
    fi
}
