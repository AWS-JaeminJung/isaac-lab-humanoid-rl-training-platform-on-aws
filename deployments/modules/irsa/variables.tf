################################################################################
# IRSA Module - Variables
################################################################################

variable "role_name" {
  description = "The name of the IAM role to create for the service account."
  type        = string
}

variable "cluster_name" {
  description = "The name of the EKS cluster. Used for tagging only."
  type        = string
}

variable "oidc_provider_arn" {
  description = "The ARN of the EKS cluster's OIDC identity provider (e.g. arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE)."
  type        = string
}

variable "namespace" {
  description = "The Kubernetes namespace of the service account that will assume this role."
  type        = string
}

variable "service_account_name" {
  description = "The Kubernetes service account name that will assume this role."
  type        = string
}

variable "policy_arns" {
  description = "A list of IAM policy ARNs to attach to the role."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "A map of tags to apply to the IAM role."
  type        = map(string)
  default     = {}
}
