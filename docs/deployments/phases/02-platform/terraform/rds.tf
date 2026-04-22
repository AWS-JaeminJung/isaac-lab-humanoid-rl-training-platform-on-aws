################################################################################
# Phase 02 - Platform: RDS PostgreSQL
#
# Shared PostgreSQL instance for Keycloak and MLflow metadata. Additional
# databases (keycloak_db, mlflow_db) are created via post-provisioning
# scripts since Terraform's AWS provider does not manage individual
# databases within an RDS instance.
################################################################################

# ---------------------------------------------------------------------------
# Secrets Manager - master password (auto-generated)
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "rds_master_password" {
  name                    = "${var.cluster_name}/rds/master-password"
  description             = "Master password for the Isaac Lab RDS PostgreSQL instance"
  recovery_window_in_days = 30

  tags = {
    Name = "${var.cluster_name}-rds-master-password"
  }
}

resource "aws_secretsmanager_secret_version" "rds_master_password" {
  secret_id = aws_secretsmanager_secret.rds_master_password.id

  secret_string = jsonencode({
    username = "isaac_admin"
    password = random_password.rds_master.result
    engine   = "postgres"
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = "postgres"
  })
}

resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>?"
}

# ---------------------------------------------------------------------------
# DB Subnet Group
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${var.cluster_name}-rds"
  description = "Subnet group for ${var.cluster_name} RDS instance"
  subnet_ids  = [local.infrastructure_subnet_id]

  tags = {
    Name = "${var.cluster_name}-rds-subnet-group"
  }
}

# ---------------------------------------------------------------------------
# DB Parameter Group (PostgreSQL 16)
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name        = "${var.cluster_name}-pg16"
  family      = "postgres16"
  description = "PostgreSQL 16 parameter group for ${var.cluster_name}"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.cluster_name}-pg16-params"
  }
}

# ---------------------------------------------------------------------------
# RDS Instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = "${var.cluster_name}-postgres"

  engine               = "postgres"
  engine_version       = "16"
  instance_class       = var.rds_instance_class
  allocated_storage    = var.rds_storage_size
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = "postgres"
  username = "isaac_admin"
  password = random_password.rds_master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [local.sg_storage_id]

  multi_az            = false
  publicly_accessible = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster_name}-postgres-final"

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  performance_insights_enabled = true

  tags = {
    Name = "${var.cluster_name}-postgres"
  }
}
