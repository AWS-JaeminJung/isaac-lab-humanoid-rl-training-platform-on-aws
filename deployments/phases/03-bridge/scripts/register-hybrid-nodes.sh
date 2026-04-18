#!/usr/bin/env bash
################################################################################
# register-hybrid-nodes.sh
#
# Registers on-prem GPU machines as EKS Hybrid Nodes via SSM and nodeadm.
#
# Modes:
#   1. Print instructions for manual registration (default)
#   2. If ON_PREM_HOSTS env var is set (comma-separated), SSH into each host
#      and run the nodeadm registration commands automatically.
#
# Prerequisites:
#   - Phase 03 terraform apply completed (SSM activation exists)
#   - On-prem hosts: Ubuntu 22.04+, NVIDIA driver installed, SSH accessible
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

CLUSTER_NAME="$(get_tf_output cluster_name)"
CLUSTER_ENDPOINT="$(get_tf_output cluster_endpoint)"
SSM_ACTIVATION_ID="$(get_tf_output ssm_activation_id)"
SSM_ACTIVATION_CODE="$(terraform -chdir="${TERRAFORM_DIR}" output -raw ssm_activation_code 2>/dev/null)"
HYBRID_NODE_ROLE_NAME="$(get_tf_output hybrid_node_role_name)"
AWS_REGION="${AWS_REGION:-us-east-1}"

log_info "Cluster:          ${CLUSTER_NAME}"
log_info "Cluster endpoint: ${CLUSTER_ENDPOINT}"
log_info "SSM Activation:   ${SSM_ACTIVATION_ID}"
log_info "Region:           ${AWS_REGION}"

# ---------------------------------------------------------------------------
# nodeadm configuration template
# ---------------------------------------------------------------------------

generate_nodeadm_config() {
    cat <<NODEADM_EOF
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    region: ${AWS_REGION}
  hybrid:
    ssm:
      activationId: ${SSM_ACTIVATION_ID}
      activationCode: ${SSM_ACTIVATION_CODE}
NODEADM_EOF
}

# ---------------------------------------------------------------------------
# Print manual registration instructions
# ---------------------------------------------------------------------------

print_instructions() {
    echo ""
    echo "=============================================================================="
    echo "  On-Prem Node Registration Instructions"
    echo "=============================================================================="
    echo ""
    echo "Run the following commands on EACH on-prem GPU machine:"
    echo ""
    echo "  # 1. Download nodeadm"
    echo "  curl -OL 'https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm'"
    echo "  chmod +x nodeadm"
    echo "  sudo mv nodeadm /usr/local/bin/"
    echo ""
    echo "  # 2. Write the node configuration"
    echo "  sudo mkdir -p /etc/eks"
    echo "  sudo tee /etc/eks/nodeadm-config.yaml <<'EOF'"
    generate_nodeadm_config
    echo "EOF"
    echo ""
    echo "  # 3. Install and register with EKS"
    echo "  sudo nodeadm install ${CLUSTER_NAME} --config-source file:///etc/eks/nodeadm-config.yaml"
    echo "  sudo nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml"
    echo ""
    echo "=============================================================================="
    echo ""
}

# ---------------------------------------------------------------------------
# Automated registration via SSH
# ---------------------------------------------------------------------------

register_host() {
    local host="$1"
    local ssh_user="${SSH_USER:-ubuntu}"
    local ssh_key="${SSH_KEY:-}"
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

    if [[ -n "${ssh_key}" ]]; then
        ssh_opts="${ssh_opts} -i ${ssh_key}"
    fi

    log_info "Registering host: ${host} (user: ${ssh_user})"

    local nodeadm_config
    nodeadm_config="$(generate_nodeadm_config)"

    # shellcheck disable=SC2029
    ssh ${ssh_opts} "${ssh_user}@${host}" bash -s <<REMOTE_EOF
set -euo pipefail

echo "--- Downloading nodeadm ---"
if ! command -v nodeadm &>/dev/null; then
    curl -sOL 'https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm'
    chmod +x nodeadm
    sudo mv nodeadm /usr/local/bin/
fi

echo "--- Writing nodeadm configuration ---"
sudo mkdir -p /etc/eks
sudo tee /etc/eks/nodeadm-config.yaml >/dev/null <<'INNER_EOF'
${nodeadm_config}
INNER_EOF

echo "--- Running nodeadm install ---"
sudo nodeadm install ${CLUSTER_NAME} --config-source file:///etc/eks/nodeadm-config.yaml

echo "--- Running nodeadm init ---"
sudo nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml

echo "--- Registration complete ---"
REMOTE_EOF

    log_success "Host ${host} registered successfully"
}

# ---------------------------------------------------------------------------
# Wait for nodes to appear in the cluster
# ---------------------------------------------------------------------------

wait_for_nodes() {
    local expected_count="$1"
    local max_wait=300
    local interval=15
    local elapsed=0

    log_info "Waiting up to ${max_wait}s for ${expected_count} hybrid node(s) to appear..."

    while (( elapsed < max_wait )); do
        local node_count
        node_count=$(kubectl get nodes --selector='node.kubernetes.io/instance-type=hybrid' --no-headers 2>/dev/null | wc -l | tr -d ' ')

        if (( node_count >= expected_count )); then
            log_success "${node_count} hybrid node(s) visible in the cluster"
            kubectl get nodes --selector='node.kubernetes.io/instance-type=hybrid' -o wide
            return 0
        fi

        log_info "Found ${node_count}/${expected_count} hybrid nodes, waiting ${interval}s..."
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done

    log_warn "Timed out waiting for hybrid nodes. Check 'kubectl get nodes' manually."
    kubectl get nodes -o wide
    return 1
}

# ===========================================================================
# Main
# ===========================================================================

step_start "Generate registration instructions"
print_instructions
step_end

if [[ -n "${ON_PREM_HOSTS:-}" ]]; then
    step_start "Automated registration via SSH"

    IFS=',' read -ra HOSTS <<< "${ON_PREM_HOSTS}"
    log_info "Registering ${#HOSTS[@]} host(s): ${ON_PREM_HOSTS}"

    for host in "${HOSTS[@]}"; do
        host="$(echo "${host}" | xargs)"  # trim whitespace
        register_host "${host}"
    done

    step_end

    step_start "Wait for hybrid nodes"
    wait_for_nodes "${#HOSTS[@]}"
    step_end
else
    log_info "Set ON_PREM_HOSTS='host1,host2,...' to automate registration via SSH."
    log_info "Optionally set SSH_USER (default: ubuntu) and SSH_KEY for authentication."
fi

log_success "Hybrid node registration step complete"
