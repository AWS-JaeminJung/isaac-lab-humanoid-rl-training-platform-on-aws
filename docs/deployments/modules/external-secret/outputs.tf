################################################################################
# External Secret Module - Outputs
################################################################################

output "k8s_secret_name" {
  description = "The name of the Kubernetes Secret created by the ExternalSecret resource."
  value       = var.secret_name
}
