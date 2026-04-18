################################################################################
# Phase 01 - Foundation: Route 53 Private DNS
#
# Private hosted zone for internal service discovery and a Route 53
# Resolver inbound endpoint so that on-premises hosts can resolve
# records in the private zone via the Direct Connect link.
################################################################################

# ------------------------------------------------------------------------------
# Private Hosted Zone
# ------------------------------------------------------------------------------

resource "aws_route53_zone" "internal" {
  name    = var.domain
  comment = "Isaac Lab internal service discovery"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = {
    Name = "${var.s3_prefix}-zone-internal"
  }

  # Prevent accidental deletion of DNS records
  lifecycle {
    prevent_destroy = true
  }
}

# ------------------------------------------------------------------------------
# Route 53 Resolver Inbound Endpoint
#
# On-premises DNS servers forward queries for the internal domain to these
# IP addresses (reachable via Direct Connect). The endpoint is placed in
# the Infrastructure subnet.
# ------------------------------------------------------------------------------

resource "aws_route53_resolver_endpoint" "inbound" {
  name               = "${var.s3_prefix}-resolver-inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.vpc_endpoint.id]

  # Two IP addresses are required for high availability, both in the
  # Infrastructure subnet (single-AZ design).
  ip_address {
    subnet_id = aws_subnet.infrastructure.id
  }

  ip_address {
    subnet_id = aws_subnet.infrastructure.id
  }

  tags = {
    Name = "${var.s3_prefix}-resolver-inbound"
  }
}
