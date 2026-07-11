locals {
  name_prefix = "voteball"
}

data "aws_db_subnet_group" "default" {
  name = "default-${var.vpc_id}"
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = "17.9"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp2"
  storage_encrypted     = true

  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = data.aws_db_subnet_group.default.name
  vpc_security_group_ids = [var.sg_rds_id]
  availability_zone      = "il-central-1b"
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  backup_window           = "04:53-05:23"
  maintenance_window      = "tue:05:32-tue:06:02"

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  deletion_protection        = false

  # Low-stakes, time-boxed poll data — no final-snapshot ceremony needed.
  skip_final_snapshot = true

  lifecycle {
    ignore_changes = [password]
  }

  tags = {
    Voteball = "rds"
  }
}
