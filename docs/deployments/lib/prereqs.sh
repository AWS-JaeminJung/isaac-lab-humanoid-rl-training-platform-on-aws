#!/usr/bin/env bash
################################################################################
# prereqs.sh - Prerequisite checking and auto-installation
#
# Validates that all required CLI tools are installed and meet minimum version
# requirements. Can auto-install missing tools on macOS (brew) and
# Debian/Ubuntu (apt).
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/prereqs.sh"
################################################################################

# Source common utilities
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Required tools: "name:min_version"
# ---------------------------------------------------------------------------
REQUIRED_TOOLS=(
    "terraform:1.9.0"
    "kubectl:1.31.0"
    "helm:3.16.0"
    "aws:2.0.0"
    "jq:1.6"
    "curl:7.0.0"
)

# ---------------------------------------------------------------------------
# version_gte - Compare two semantic versions (a >= b)
# Returns 0 if version_a >= version_b, 1 otherwise
# Usage: version_gte "1.10.2" "1.9.0"
# ---------------------------------------------------------------------------
version_gte() {
    local version_a="${1:?version_a required}"
    local version_b="${2:?version_b required}"

    # If they are equal, return true
    if [[ "${version_a}" == "${version_b}" ]]; then
        return 0
    fi

    # Compare using sort -V (version sort)
    local lower
    lower="$(printf '%s\n%s' "${version_a}" "${version_b}" | sort -V | head -n1)"
    if [[ "${lower}" == "${version_b}" ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _extract_version - Extract version number from a tool's --version output
# Handles various output formats
# ---------------------------------------------------------------------------
_extract_version() {
    local tool="${1:?tool required}"
    local raw_version=""

    case "${tool}" in
        terraform)
            raw_version="$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null)" \
                || raw_version="$(terraform version 2>/dev/null | head -n1)"
            ;;
        kubectl)
            raw_version="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null)" \
                || raw_version="$(kubectl version --client 2>/dev/null | head -n1)"
            ;;
        helm)
            raw_version="$(helm version --short 2>/dev/null)"
            ;;
        aws)
            raw_version="$(aws --version 2>&1 | head -n1)"
            ;;
        jq)
            raw_version="$(jq --version 2>&1)"
            ;;
        curl)
            raw_version="$(curl --version 2>&1 | head -n1)"
            ;;
        *)
            raw_version="$(${tool} --version 2>&1 | head -n1)"
            ;;
    esac

    # Extract the first semver-like pattern (digits.digits.digits)
    echo "${raw_version}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# ---------------------------------------------------------------------------
# check_tool - Check if a tool exists and meets minimum version
# Usage: check_tool "terraform" "1.9.0"
# Returns: 0=ok, 1=missing, 2=version too low
# ---------------------------------------------------------------------------
check_tool() {
    local tool="${1:?tool name required}"
    local min_version="${2:?minimum version required}"

    if ! command -v "${tool}" &>/dev/null; then
        return 1
    fi

    local current_version
    current_version="$(_extract_version "${tool}")"

    if [[ -z "${current_version}" ]]; then
        log_warn "Could not determine version for ${tool}, assuming OK"
        return 0
    fi

    if version_gte "${current_version}" "${min_version}"; then
        return 0
    else
        return 2
    fi
}

# ---------------------------------------------------------------------------
# check_prereqs - Check all required tools, report status
# Returns 0 if all OK, 1 if any missing/outdated
# Populates global MISSING_TOOLS and OUTDATED_TOOLS arrays
# ---------------------------------------------------------------------------
declare -ga MISSING_TOOLS=()
declare -ga OUTDATED_TOOLS=()

check_prereqs() {
    MISSING_TOOLS=()
    OUTDATED_TOOLS=()
    local all_ok=true

    log_info "Checking prerequisites..."
    echo "" >&2

    for entry in "${REQUIRED_TOOLS[@]}"; do
        local tool="${entry%%:*}"
        local min_version="${entry##*:}"
        local status_text=""
        local current_version=""

        if ! command -v "${tool}" &>/dev/null; then
            status_text="${_CLR_RED}MISSING${_CLR_RESET}"
            MISSING_TOOLS+=("${entry}")
            all_ok=false
        else
            current_version="$(_extract_version "${tool}")"
            if [[ -z "${current_version}" ]]; then
                status_text="${_CLR_YELLOW}UNKNOWN VERSION${_CLR_RESET}"
            elif version_gte "${current_version}" "${min_version}"; then
                status_text="${_CLR_GREEN}${current_version}${_CLR_RESET}"
            else
                status_text="${_CLR_RED}${current_version} (need >=${min_version})${_CLR_RESET}"
                OUTDATED_TOOLS+=("${entry}")
                all_ok=false
            fi
        fi

        printf "  %-14s %-10s %b\n" "${tool}" ">=${min_version}" "${status_text}" >&2
    done

    echo "" >&2

    if ${all_ok}; then
        log_success "All prerequisites satisfied"
        return 0
    else
        if (( ${#MISSING_TOOLS[@]} > 0 )); then
            log_error "Missing tools: ${MISSING_TOOLS[*]}"
        fi
        if (( ${#OUTDATED_TOOLS[@]} > 0 )); then
            log_error "Outdated tools: ${OUTDATED_TOOLS[*]}"
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _detect_os - Detect OS and package manager
# Sets OS_TYPE and PKG_MANAGER globals
# ---------------------------------------------------------------------------
_detect_os() {
    OS_TYPE=""
    PKG_MANAGER=""

    case "$(uname -s)" in
        Darwin*)
            OS_TYPE="macos"
            PKG_MANAGER="brew"
            ;;
        Linux*)
            if [[ -f /etc/debian_version ]]; then
                OS_TYPE="debian"
                PKG_MANAGER="apt"
            elif [[ -f /etc/redhat-release ]]; then
                OS_TYPE="redhat"
                PKG_MANAGER="yum"
            else
                OS_TYPE="linux-unknown"
                PKG_MANAGER=""
            fi
            ;;
        *)
            OS_TYPE="unknown"
            PKG_MANAGER=""
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _install_tool - Install a single tool based on OS
# ---------------------------------------------------------------------------
_install_tool() {
    local tool="${1:?tool name required}"

    _detect_os

    case "${tool}" in
        terraform)
            _install_terraform
            ;;
        kubectl)
            _install_kubectl
            ;;
        helm)
            _install_helm
            ;;
        aws)
            _install_awscli
            ;;
        jq)
            _install_generic "jq"
            ;;
        curl)
            _install_generic "curl"
            ;;
        *)
            log_error "No install method defined for: ${tool}"
            return 1
            ;;
    esac
}

_install_generic() {
    local pkg="${1}"
    case "${PKG_MANAGER}" in
        brew) brew install "${pkg}" ;;
        apt)  sudo apt-get update -qq && sudo apt-get install -y -qq "${pkg}" ;;
        yum)  sudo yum install -y "${pkg}" ;;
        *)    die "Unsupported package manager for ${pkg} installation" ;;
    esac
}

_install_terraform() {
    log_info "Installing Terraform..."
    case "${PKG_MANAGER}" in
        brew)
            brew tap hashicorp/tap 2>/dev/null || true
            brew install hashicorp/tap/terraform
            ;;
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y -qq gnupg software-properties-common
            local keyring="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
            if [[ ! -f "${keyring}" ]]; then
                curl -fsSL https://apt.releases.hashicorp.com/gpg | \
                    sudo gpg --dearmor -o "${keyring}"
            fi
            echo "deb [signed-by=${keyring}] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
                sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
            sudo apt-get update -qq
            sudo apt-get install -y -qq terraform
            ;;
        *)
            die "Unsupported OS for Terraform auto-install. Please install manually."
            ;;
    esac
}

_install_kubectl() {
    log_info "Installing kubectl..."
    case "${PKG_MANAGER}" in
        brew)
            brew install kubectl
            ;;
        apt|yum)
            local arch
            arch="$(uname -m)"
            case "${arch}" in
                x86_64)  arch="amd64" ;;
                aarch64) arch="arm64" ;;
            esac
            local version
            version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
            curl -fsSLo /tmp/kubectl \
                "https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
            sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
            rm -f /tmp/kubectl
            ;;
        *)
            die "Unsupported OS for kubectl auto-install. Please install manually."
            ;;
    esac
}

_install_helm() {
    log_info "Installing Helm via get-helm-3 script..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

_install_awscli() {
    log_info "Installing AWS CLI v2..."
    case "${PKG_MANAGER}" in
        brew)
            brew install awscli
            ;;
        apt|yum)
            local arch
            arch="$(uname -m)"
            local url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
            local tmpdir
            tmpdir="$(mktemp -d)"
            curl -fsSLo "${tmpdir}/awscliv2.zip" "${url}"
            unzip -q "${tmpdir}/awscliv2.zip" -d "${tmpdir}"
            sudo "${tmpdir}/aws/install" --update
            rm -rf "${tmpdir}"
            ;;
        *)
            die "Unsupported OS for AWS CLI auto-install. Please install manually."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# auto_install_prereqs - Attempt to install all missing/outdated tools
# ---------------------------------------------------------------------------
auto_install_prereqs() {
    # Run check first to populate missing/outdated arrays
    if check_prereqs; then
        return 0
    fi

    _detect_os
    log_info "Detected OS: ${OS_TYPE}, package manager: ${PKG_MANAGER}"

    if [[ -z "${PKG_MANAGER}" ]]; then
        die "Cannot auto-install on this OS. Please install tools manually."
    fi

    local tools_to_install=()
    for entry in "${MISSING_TOOLS[@]}" "${OUTDATED_TOOLS[@]}"; do
        tools_to_install+=("${entry%%:*}")
    done

    if (( ${#tools_to_install[@]} == 0 )); then
        log_success "Nothing to install"
        return 0
    fi

    log_info "Will attempt to install: ${tools_to_install[*]}"
    confirm "Proceed with auto-installation?" || die "Installation cancelled"

    for tool in "${tools_to_install[@]}"; do
        step_start "Install ${tool}"
        if _install_tool "${tool}"; then
            step_end 0
        else
            step_end 1
            die "Failed to install ${tool}"
        fi
    done

    # Verify after installation
    log_info "Verifying installations..."
    check_prereqs
}

# ---------------------------------------------------------------------------
# check_aws_auth - Verify AWS authentication
# ---------------------------------------------------------------------------
check_aws_auth() {
    log_info "Checking AWS authentication..."

    local identity
    if ! identity="$(aws sts get-caller-identity --output json 2>&1)"; then
        die "AWS authentication failed. Run 'aws configure' or set AWS credentials.\n  ${identity}"
    fi

    local account_id arn
    account_id="$(echo "${identity}" | jq -r '.Account')"
    arn="$(echo "${identity}" | jq -r '.Arn')"

    log_success "AWS authenticated - Account: ${account_id}, ARN: ${arn}"
    echo "${account_id}"
}

# ---------------------------------------------------------------------------
# check_kubeconfig - Verify kubectl connectivity
# ---------------------------------------------------------------------------
check_kubeconfig() {
    log_info "Checking Kubernetes connectivity..."

    local context
    context="$(kubectl config current-context 2>/dev/null)" \
        || die "No kubectl context configured. Run 'aws eks update-kubeconfig' first."

    if ! kubectl cluster-info &>/dev/null; then
        die "Cannot connect to Kubernetes cluster (context: ${context}). Check VPN/Direct Connect."
    fi

    local server
    server="$(kubectl cluster-info 2>/dev/null | head -n1 | grep -oE 'https://[^ ]+')" || server="unknown"

    log_success "Kubernetes connected - Context: ${context}, Server: ${server}"
    echo "${context}"
}
