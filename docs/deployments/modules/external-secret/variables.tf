################################################################################
# External Secret Module - Variables
################################################################################

variable "secret_name" {
  description = "The name of the Kubernetes Secret that the ExternalSecret will create and manage."
  type        = string
}

variable "namespace" {
  description = "The Kubernetes namespace in which to create the ExternalSecret resource."
  type        = string
}

variable "secrets_manager_key" {
  description = "The name or ARN of the secret in AWS Secrets Manager to read from."
  type        = string
}

variable "refresh_interval" {
  description = "How often the External Secrets Operator should poll Secrets Manager for updates (e.g. '1h', '15m', '30s')."
  type        = string
  default     = "1h"
}

variable "data_map" {
  description = <<-EOT
    A map whose keys are the desired Kubernetes Secret data keys and whose
    values are the corresponding JSON property names inside the Secrets Manager
    secret. For example: { "db-password" = "password", "db-username" = "username" }.
  EOT
  type        = map(string)
}

variable "cluster_secret_store_name" {
  description = "The name of the ClusterSecretStore resource configured for AWS Secrets Manager."
  type        = string
  default     = "aws-secrets-manager"
}
