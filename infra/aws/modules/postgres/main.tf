# ==================== RDS for PostgreSQL ====================
resource "random_password" "admin" {
  length  = 32
  special = false # keeps the password URL-safe for connection strings, and avoids the characters RDS rejects
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

# No egress rules: the database only answers connections, it never opens them.
resource "aws_security_group" "this" {
  name        = "${var.name}-postgres"
  description = "PostgreSQL, reachable from the EKS cluster only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each                     = var.allowed_security_groups
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# trivy:ignore:AVD-AWS-0177 Deletion protection is off so the dev environment can be destroyed. Enable it for long-lived environments.
resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.postgres_version # a major version: RDS picks its default minor and keeps patching it
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  # RDS creates exactly one database at launch. The rest are created from inside the VPC
  # (see the postgres_databases output), because Terraform cannot reach this private server.
  db_name  = var.databases[0]
  username = var.admin_login
  password = random_password.admin.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false
  # rds.force_ssl is on by default from PostgreSQL 15, which is what sslmode=require relies on.

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  # Allows IAM tokens as well as the password, for anyone who later wants passwordless connections.
  iam_database_authentication_enabled = true

  # Dev is disposable: no final snapshot to clean up after `terraform destroy`.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true
}
