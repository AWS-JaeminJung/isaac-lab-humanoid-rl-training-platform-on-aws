################################################################################
# Phase 01 - Foundation: Security Groups
#
# Five security groups implementing least-privilege network segmentation:
#   1. SG-GPU-Node     - GPU compute inter-node + management inbound
#   2. SG-Mgmt-Node    - Management plane (ALB inbound, service egress)
#   3. SG-ALB          - Application Load Balancer (on-prem HTTPS inbound)
#   4. SG-VPC-Endpoint - PrivateLink interfaces (VPC-wide HTTPS inbound)
#   5. SG-Storage      - FSx Lustre, PostgreSQL, Redis (selective inbound)
################################################################################

# ==============================================================================
# 1. SG-GPU-Node
# ==============================================================================

resource "aws_security_group" "gpu_node" {
  name_prefix = "${var.s3_prefix}-sg-gpu-node-"
  description = "GPU compute nodes: inter-node all-traffic, management inbound for Ray"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.s3_prefix}-sg-gpu-node"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: All traffic between GPU nodes (self-referencing)
resource "aws_security_group_rule" "gpu_node_self_ingress" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.gpu_node.id
  self              = true
  description       = "All traffic between GPU nodes (NCCL, GDR, Ray object store)"
}

# Ingress: Ray Dashboard (8265) from Management nodes
resource "aws_security_group_rule" "gpu_node_ray_dashboard_from_mgmt" {
  type                     = "ingress"
  from_port                = 8265
  to_port                  = 8265
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gpu_node.id
  source_security_group_id = aws_security_group.mgmt_node.id
  description              = "Ray Dashboard from Management nodes"
}

# Ingress: Ray GCS / Redis (6379) from Management nodes
resource "aws_security_group_rule" "gpu_node_ray_gcs_from_mgmt" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gpu_node.id
  source_security_group_id = aws_security_group.mgmt_node.id
  description              = "Ray GCS / Redis from Management nodes"
}

# Egress: All traffic between GPU nodes (self-referencing)
resource "aws_security_group_rule" "gpu_node_self_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.gpu_node.id
  self              = true
  description       = "All traffic between GPU nodes"
}

# Egress: FSx Lustre (988) to Storage
resource "aws_security_group_rule" "gpu_node_fsx_to_storage" {
  type                     = "egress"
  from_port                = 988
  to_port                  = 988
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gpu_node.id
  source_security_group_id = aws_security_group.storage.id
  description              = "FSx Lustre to Storage security group"
}

# ==============================================================================
# 2. SG-Mgmt-Node
# ==============================================================================

resource "aws_security_group" "mgmt_node" {
  name_prefix = "${var.s3_prefix}-sg-mgmt-node-"
  description = "Management nodes: ALB inbound, GPU inbound, service egress"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.s3_prefix}-sg-mgmt-node"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: HTTP (80) from ALB
resource "aws_security_group_rule" "mgmt_node_http_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mgmt_node.id
  source_security_group_id = aws_security_group.alb.id
  description              = "HTTP from ALB"
}

# Ingress: HTTPS (443) from ALB
resource "aws_security_group_rule" "mgmt_node_https_from_alb" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mgmt_node.id
  source_security_group_id = aws_security_group.alb.id
  description              = "HTTPS from ALB"
}

# Ingress: All traffic from GPU nodes
resource "aws_security_group_rule" "mgmt_node_all_from_gpu" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.mgmt_node.id
  source_security_group_id = aws_security_group.gpu_node.id
  description              = "All traffic from GPU nodes"
}

# Egress: HTTPS (443) to VPC Endpoint security group
resource "aws_security_group_rule" "mgmt_node_https_to_vpce" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mgmt_node.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
  description              = "HTTPS to VPC Endpoints"
}

# Egress: PostgreSQL (5432) to Storage
resource "aws_security_group_rule" "mgmt_node_pg_to_storage" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mgmt_node.id
  source_security_group_id = aws_security_group.storage.id
  description              = "PostgreSQL to Storage security group"
}

# Egress: Redis (6379) to Storage
resource "aws_security_group_rule" "mgmt_node_redis_to_storage" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mgmt_node.id
  source_security_group_id = aws_security_group.storage.id
  description              = "Redis to Storage security group"
}

# ==============================================================================
# 3. SG-ALB
# ==============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "${var.s3_prefix}-sg-alb-"
  description = "Application Load Balancer: on-prem HTTPS inbound, management plane egress"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.s3_prefix}-sg-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: HTTPS (443) from on-premises network
resource "aws_security_group_rule" "alb_https_from_onprem" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = [var.onprem_cidr]
  description       = "HTTPS from on-premises network (${var.onprem_cidr})"
}

# Egress: HTTP (80) to Management nodes
resource "aws_security_group_rule" "alb_http_to_mgmt" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.mgmt_node.id
  description              = "HTTP to Management nodes"
}

# Egress: HTTPS (443) to Management nodes
resource "aws_security_group_rule" "alb_https_to_mgmt" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.mgmt_node.id
  description              = "HTTPS to Management nodes"
}

# ==============================================================================
# 4. SG-VPC-Endpoint
# ==============================================================================

resource "aws_security_group" "vpc_endpoint" {
  name_prefix = "${var.s3_prefix}-sg-vpce-"
  description = "VPC Endpoints: HTTPS inbound from entire VPC"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.s3_prefix}-sg-vpce"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: HTTPS (443) from VPC CIDR
resource "aws_security_group_rule" "vpce_https_from_vpc" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.vpc_endpoint.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "HTTPS from VPC (${var.vpc_cidr})"
}

# ==============================================================================
# 5. SG-Storage
# ==============================================================================

resource "aws_security_group" "storage" {
  name_prefix = "${var.s3_prefix}-sg-storage-"
  description = "Storage services: FSx Lustre, PostgreSQL, Redis - selective inbound"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.s3_prefix}-sg-storage"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: FSx Lustre (988) from GPU nodes
resource "aws_security_group_rule" "storage_fsx_from_gpu" {
  type                     = "ingress"
  from_port                = 988
  to_port                  = 988
  protocol                 = "tcp"
  security_group_id        = aws_security_group.storage.id
  source_security_group_id = aws_security_group.gpu_node.id
  description              = "FSx Lustre from GPU nodes"
}

# Ingress: PostgreSQL (5432) from Management nodes
resource "aws_security_group_rule" "storage_pg_from_mgmt" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.storage.id
  source_security_group_id = aws_security_group.mgmt_node.id
  description              = "PostgreSQL from Management nodes"
}

# Ingress: Redis (6379) from Management nodes
resource "aws_security_group_rule" "storage_redis_from_mgmt" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.storage.id
  source_security_group_id = aws_security_group.mgmt_node.id
  description              = "Redis from Management nodes"
}
