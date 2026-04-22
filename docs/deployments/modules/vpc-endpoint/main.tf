################################################################################
# VPC Endpoint Module
#
# Creates either a Gateway or Interface VPC endpoint for AWS services.
# Gateway endpoints are used for S3 and DynamoDB; Interface endpoints use
# AWS PrivateLink for all other supported services.
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  is_gateway   = lower(var.type) == "gateway"
  is_interface = lower(var.type) == "interface"
}

resource "aws_vpc_endpoint" "this" {
  vpc_id            = var.vpc_id
  service_name      = var.service_name
  vpc_endpoint_type = local.is_gateway ? "Gateway" : "Interface"

  # Gateway endpoint settings
  route_table_ids = local.is_gateway ? var.route_table_ids : null

  # Interface endpoint settings
  subnet_ids         = local.is_interface ? var.subnet_ids : null
  security_group_ids = local.is_interface ? var.security_group_ids : null
  private_dns_enabled = local.is_interface ? var.private_dns_enabled : null

  tags = merge(
    var.tags,
    {
      Name = var.service_name
    },
  )
}
