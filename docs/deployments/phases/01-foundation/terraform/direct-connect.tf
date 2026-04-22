################################################################################
# Phase 01 - Foundation: Direct Connect
#
# Creates a Virtual Private Gateway and associates it with the existing
# Direct Connect Gateway. The physical DX connection, DX Gateway, and
# on-premises router configuration are prerequisites managed outside of
# this Terraform configuration.
################################################################################

# ------------------------------------------------------------------------------
# Virtual Private Gateway
# ------------------------------------------------------------------------------

resource "aws_vpn_gateway" "vgw" {
  vpc_id          = aws_vpc.main.id
  amazon_side_asn = 64512

  tags = {
    Name = "${var.s3_prefix}-vgw"
  }
}

# ------------------------------------------------------------------------------
# DX Gateway Association
#
# Associates the VGW with the pre-existing Direct Connect Gateway so that
# on-premises prefixes are propagated into the VPC route tables and VPC
# prefixes are advertised back to on-prem via BGP.
# ------------------------------------------------------------------------------

resource "aws_dx_gateway_association" "this" {
  dx_gateway_id         = var.dx_gateway_id
  associated_gateway_id = aws_vpn_gateway.vgw.id

  allowed_prefixes = [var.vpc_cidr]
}

# ------------------------------------------------------------------------------
# Enable VGW Route Propagation on the Private Route Table
#
# This allows BGP-learned routes from Direct Connect to be automatically
# inserted into the route table.
# ------------------------------------------------------------------------------

resource "aws_vpn_gateway_route_propagation" "private" {
  vpn_gateway_id = aws_vpn_gateway.vgw.id
  route_table_id = aws_route_table.private.id
}
