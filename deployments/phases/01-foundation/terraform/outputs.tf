################################################################################
# Phase 01 - Foundation: Outputs
#
# All values consumed by downstream phases (02-platform, 03-bridge, etc.)
# via terraform_remote_state data sources.
################################################################################

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the Isaac Lab VPC."
  value       = aws_vpc.main.id
}

# ------------------------------------------------------------------------------
# Subnets
# ------------------------------------------------------------------------------

output "gpu_subnet_id" {
  description = "ID of the GPU Compute subnet."
  value       = aws_subnet.gpu_compute.id
}

output "management_subnet_id" {
  description = "ID of the Management subnet."
  value       = aws_subnet.management.id
}

output "infrastructure_subnet_id" {
  description = "ID of the Infrastructure subnet."
  value       = aws_subnet.infrastructure.id
}

output "reserved_subnet_id" {
  description = "ID of the Reserved subnet."
  value       = aws_subnet.reserved.id
}

# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------

output "sg_gpu_node_id" {
  description = "ID of the GPU Node security group."
  value       = aws_security_group.gpu_node.id
}

output "sg_mgmt_node_id" {
  description = "ID of the Management Node security group."
  value       = aws_security_group.mgmt_node.id
}

output "sg_alb_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

output "sg_vpc_endpoint_id" {
  description = "ID of the VPC Endpoint security group."
  value       = aws_security_group.vpc_endpoint.id
}

output "sg_storage_id" {
  description = "ID of the Storage security group."
  value       = aws_security_group.storage.id
}

# ------------------------------------------------------------------------------
# DNS
# ------------------------------------------------------------------------------

output "hosted_zone_id" {
  description = "ID of the Route 53 private hosted zone."
  value       = aws_route53_zone.internal.zone_id
}

# ------------------------------------------------------------------------------
# Certificates
# ------------------------------------------------------------------------------

output "acm_certificate_arn" {
  description = "ARN of the validated ACM wildcard certificate for the internal domain."
  value       = aws_acm_certificate_validation.internal.certificate_arn
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------

output "vgw_id" {
  description = "ID of the Virtual Private Gateway attached to the VPC."
  value       = aws_vpn_gateway.vgw.id
}

output "route_table_id" {
  description = "ID of the private route table."
  value       = aws_route_table.private.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 Gateway VPC Endpoint."
  value       = module.s3_gateway_endpoint.endpoint_id
}
