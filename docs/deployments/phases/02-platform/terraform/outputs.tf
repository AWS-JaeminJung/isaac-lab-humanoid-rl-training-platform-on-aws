################################################################################
# Phase 02 - Platform: Outputs
#
# Exported values consumed by subsequent phases and deployment scripts.
################################################################################

# ===========================================================================
# EKS Cluster
# ===========================================================================

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate authority data for the EKS cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC identity provider."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the EKS OIDC identity provider (without https:// prefix)."
  value       = local.oidc_provider_url
}

# ===========================================================================
# RDS
# ===========================================================================

output "rds_endpoint" {
  description = "Endpoint (hostname) of the RDS PostgreSQL instance."
  value       = aws_db_instance.this.address
}

output "rds_port" {
  description = "Port number of the RDS PostgreSQL instance."
  value       = aws_db_instance.this.port
}

# ===========================================================================
# FSx for Lustre
# ===========================================================================

output "fsx_filesystem_id" {
  description = "ID of the FSx for Lustre filesystem."
  value       = aws_fsx_lustre_file_system.training.id
}

output "fsx_mount_name" {
  description = "Mount name of the FSx for Lustre filesystem."
  value       = aws_fsx_lustre_file_system.training.mount_name
}

# ===========================================================================
# S3 Buckets
# ===========================================================================

output "s3_checkpoints_bucket" {
  description = "Name of the S3 bucket for training checkpoints."
  value       = module.s3_checkpoints.bucket_name
}

output "s3_models_bucket" {
  description = "Name of the S3 bucket for MLflow model artifacts."
  value       = module.s3_models.bucket_name
}

output "s3_logs_archive_bucket" {
  description = "Name of the S3 bucket for log archives."
  value       = module.s3_logs_archive.bucket_name
}

output "s3_training_data_bucket" {
  description = "Name of the S3 bucket for training data."
  value       = module.s3_training_data.bucket_name
}

# ===========================================================================
# ECR
# ===========================================================================

output "ecr_repository_url" {
  description = "URL of the ECR repository for training images."
  value       = aws_ecr_repository.training.repository_url
}

# ===========================================================================
# GPU Baseline Node Group
# ===========================================================================

output "gpu_baseline_node_group_name" {
  description = "Name of the GPU baseline managed node group."
  value       = aws_eks_node_group.gpu_baseline.node_group_name
}

output "gpu_baseline_node_role_arn" {
  description = "ARN of the IAM role for GPU baseline nodes."
  value       = aws_iam_role.gpu_baseline_node.arn
}

# ===========================================================================
# Karpenter (GPU Burst)
# ===========================================================================

output "karpenter_role_arn" {
  description = "ARN of the Karpenter controller IAM role (IRSA)."
  value       = module.irsa_karpenter.role_arn
}

output "karpenter_instance_profile_name" {
  description = "Name of the Karpenter node instance profile."
  value       = aws_iam_instance_profile.karpenter.name
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue for Karpenter."
  value       = aws_sqs_queue.karpenter_interruption.name
}

# ===========================================================================
# IRSA Role ARNs (for add-on and Helm chart installation)
# ===========================================================================

output "irsa_ebs_csi_role_arn" {
  description = "ARN of the IAM role for the EBS CSI driver service account."
  value       = module.irsa_ebs_csi.role_arn
}

output "irsa_fsx_csi_role_arn" {
  description = "ARN of the IAM role for the FSx CSI driver service account."
  value       = module.irsa_fsx_csi.role_arn
}

output "irsa_alb_controller_role_arn" {
  description = "ARN of the IAM role for the ALB controller service account."
  value       = module.irsa_alb_controller.role_arn
}

output "irsa_external_secrets_role_arn" {
  description = "ARN of the IAM role for the External Secrets Operator service account."
  value       = module.irsa_external_secrets.role_arn
}

output "irsa_mlflow_role_arn" {
  description = "ARN of the IAM role for the MLflow service account."
  value       = module.irsa_mlflow.role_arn
}

output "irsa_fluent_bit_role_arn" {
  description = "ARN of the IAM role for the Fluent Bit service account."
  value       = module.irsa_fluent_bit.role_arn
}

output "irsa_training_job_role_arn" {
  description = "ARN of the IAM role for the training job service account."
  value       = module.irsa_training_job.role_arn
}

# ===========================================================================
# Karpenter Node Role (for EC2NodeClass)
# ===========================================================================

output "karpenter_node_role_arn" {
  description = "ARN of the IAM role assumed by Karpenter-provisioned nodes."
  value       = aws_iam_role.karpenter_node.arn
}
