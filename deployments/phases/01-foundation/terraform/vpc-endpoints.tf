################################################################################
# Phase 01 - Foundation: VPC Endpoints
#
# S3 Gateway Endpoint + 17 Interface Endpoints for AWS service access
# without traversing the public internet. All interface endpoints land in
# the Infrastructure subnet and share the SG-VPC-Endpoint security group.
################################################################################

# ------------------------------------------------------------------------------
# S3 Gateway Endpoint
# ------------------------------------------------------------------------------

module "s3_gateway_endpoint" {
  source = "../../../modules/vpc-endpoint"

  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
  type         = "gateway"

  route_table_ids = [aws_route_table.private.id]

  tags = {
    Name = "${var.s3_prefix}-vpce-s3"
  }
}

# ------------------------------------------------------------------------------
# Interface Endpoints
# ------------------------------------------------------------------------------

locals {
  interface_endpoints = {
    eks                 = "com.amazonaws.${data.aws_region.current.name}.eks"
    eks_auth            = "com.amazonaws.${data.aws_region.current.name}.eks-auth"
    ecr_api             = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
    ecr_dkr             = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
    sts                 = "com.amazonaws.${data.aws_region.current.name}.sts"
    ec2                 = "com.amazonaws.${data.aws_region.current.name}.ec2"
    elasticloadbalancing = "com.amazonaws.${data.aws_region.current.name}.elasticloadbalancing"
    logs                = "com.amazonaws.${data.aws_region.current.name}.logs"
    monitoring          = "com.amazonaws.${data.aws_region.current.name}.monitoring"
    autoscaling         = "com.amazonaws.${data.aws_region.current.name}.autoscaling"
    sqs                 = "com.amazonaws.${data.aws_region.current.name}.sqs"
    ssm                 = "com.amazonaws.${data.aws_region.current.name}.ssm"
    ssmmessages         = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
    ec2messages         = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
    fsx                 = "com.amazonaws.${data.aws_region.current.name}.fsx"
    kms                 = "com.amazonaws.${data.aws_region.current.name}.kms"
    secretsmanager      = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  }
}

module "interface_endpoints" {
  source   = "../../../modules/vpc-endpoint"
  for_each = local.interface_endpoints

  vpc_id       = aws_vpc.main.id
  service_name = each.value
  type         = "interface"

  subnet_ids          = [aws_subnet.infrastructure.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.s3_prefix}-vpce-${each.key}"
  }
}
