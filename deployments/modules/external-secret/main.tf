################################################################################
# External Secret Module
#
# Creates a Kubernetes ExternalSecret custom resource that syncs secret data
# from AWS Secrets Manager into a native Kubernetes Secret. This relies on
# the External Secrets Operator (ESO) being installed in the cluster and a
# ClusterSecretStore already configured for AWS Secrets Manager.
#
# The module uses the kubernetes_manifest resource so that no additional
# CRD-aware provider is needed -- just the standard hashicorp/kubernetes
# provider.
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

# ---------------------------------------------------------------------------
# ExternalSecret CRD manifest
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"

    metadata = {
      name      = var.secret_name
      namespace = var.namespace
    }

    spec = {
      refreshInterval = var.refresh_interval

      secretStoreRef = {
        name = var.cluster_secret_store_name
        kind = "ClusterSecretStore"
      }

      target = {
        name           = var.secret_name
        creationPolicy = "Owner"
      }

      data = [
        for k8s_key, sm_property in var.data_map : {
          secretKey = k8s_key
          remoteRef = {
            key      = var.secrets_manager_key
            property = sm_property
          }
        }
      ]
    }
  }
}
