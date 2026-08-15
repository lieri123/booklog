# RDS Postgres, in the private subnets, unreachable from the internet.


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
