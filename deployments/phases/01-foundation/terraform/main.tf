################################################################################
# Phase 01 - Foundation: VPC, Subnets, and Routing
#
# Single-AZ network layout optimised for GPU compute locality.
# All egress (including internet) flows through the Direct Connect link
# to on-premises and out via the corporate gateway -- there is no IGW or
# NAT Gateway in this VPC.
################################################################################

# ------------------------------------------------------------------------------
# Data Sources
# ------------------------------------------------------------------------------

data "aws_region" "current" {}

# S3 prefix list used by the route table to steer S3 traffic to the gateway
# endpoint instead of over Direct Connect.
data "aws_prefix_list" "s3" {
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${data.aws_region.current.name}.s3"]
  }
}

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.s3_prefix}-vpc"
  }
}

# ------------------------------------------------------------------------------
# Subnets (all in the same AZ for GPU co-location)
# ------------------------------------------------------------------------------

resource "aws_subnet" "gpu_compute" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["gpu_compute"]
  availability_zone = var.aws_az

  tags = {
    Name = "${var.s3_prefix}-gpu-compute"
    Tier = "gpu-compute"
  }
}

resource "aws_subnet" "management" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["management"]
  availability_zone = var.aws_az

  tags = {
    Name = "${var.s3_prefix}-management"
    Tier = "management"
  }
}

resource "aws_subnet" "infrastructure" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["infrastructure"]
  availability_zone = var.aws_az

  tags = {
    Name = "${var.s3_prefix}-infrastructure"
    Tier = "infrastructure"
  }
}

resource "aws_subnet" "reserved" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["reserved"]
  availability_zone = var.aws_az

  tags = {
    Name = "${var.s3_prefix}-reserved"
    Tier = "reserved"
  }
}

# ------------------------------------------------------------------------------
# Route Table (private -- no IGW)
# ------------------------------------------------------------------------------

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Local route for VPC CIDR is implicit, but we tag the table for clarity.

  tags = {
    Name = "${var.s3_prefix}-private-rt"
  }
}

# On-premises CIDR via the Virtual Private Gateway (Direct Connect)
resource "aws_route" "onprem_via_vgw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.onprem_cidr
  gateway_id             = aws_vpn_gateway.vgw.id
}

# Default route to on-prem gateway (internet egress via DX -> corporate firewall)
resource "aws_route" "default_via_vgw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_vpn_gateway.vgw.id
}

# S3 prefix list -> S3 Gateway Endpoint (managed by the endpoint association)
# The S3 Gateway endpoint automatically adds its route when associated with
# the route table. We create the association in vpc-endpoints.tf.

# ------------------------------------------------------------------------------
# Route Table Associations
# ------------------------------------------------------------------------------

resource "aws_route_table_association" "gpu_compute" {
  subnet_id      = aws_subnet.gpu_compute.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "management" {
  subnet_id      = aws_subnet.management.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "infrastructure" {
  subnet_id      = aws_subnet.infrastructure.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "reserved" {
  subnet_id      = aws_subnet.reserved.id
  route_table_id = aws_route_table.private.id
}
