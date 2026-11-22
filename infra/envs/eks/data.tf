# RDS Postgres, in the private subnets, identical to the ECS stack's instance so
# load test results transfer. The point of this exercise is to change the
# compute tier and nothing else.

resource "aws_db_subnet_group" "main" {
  name_prefix = "${local.name}-"
  description = "Private subnets for RDS"
  subnet_ids  = aws_subnet.private[*].id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = local.name }
}

resource "aws_db_instance" "main" {
  identifier_prefix = "${local.name}-"

  engine         = "postgres"
  engine_version = var.postgres_version

  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "booktracker"
  username = "booktracker"

  # RDS generates and rotates the password into Secrets Manager, so it never
  # enters Terraform state. The chart reads it through database.existingSecret,
  # which something in-cluster has to populate - see docs/kubernetes.md.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  auto_minor_version_upgrade = false

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = { Name = local.name }
}
