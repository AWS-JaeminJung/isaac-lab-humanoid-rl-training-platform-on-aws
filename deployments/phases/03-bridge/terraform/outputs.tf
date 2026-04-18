################################################################################
# Phase 03 - Bridge: Outputs
#
# Exported values consumed by registration scripts and subsequent phases.
################################################################################

# ===========================================================================
# SSM Hybrid Activation
# ===========================================================================

output "ssm_activation_id" {
  description = "ID of the SSM Hybrid Activation (used during on-prem node registration)."
  value       = aws_ssm_activation.hybrid_nodes.id
}

output "ssm_activation_code" {
  description = "Activation code for the SSM Hybrid Activation (sensitive - needed for node registration)."
  value       = aws_ssm_activation.hybrid_nodes.activation_code
  sensitive   = true
}

# ===========================================================================
# Hybrid Node IAM Role
# ===========================================================================

output "hybrid_node_role_arn" {
  description = "ARN of the IAM role assumed by hybrid on-prem nodes."
  value       = aws_iam_role.hybrid_node.arn
}

output "hybrid_node_role_name" {
  description = "Name of the IAM role assumed by hybrid on-prem nodes."
  value       = aws_iam_role.hybrid_node.name
}

# ===========================================================================
# Cluster Info (pass-through for scripts)
# ===========================================================================

output "cluster_name" {
  description = "Name of the EKS cluster (pass-through from Phase 02)."
  value       = local.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster (pass-through from Phase 02)."
  value       = local.cluster_endpoint
}
