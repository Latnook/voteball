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

  # Restore from the most recent final snapshot if scripts/find-latest-snapshot.sh
  # found one (see terraform/snapshot.auto.tfvars); null means create empty.
  snapshot_identifier = var.snapshot_identifier

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

  # Take a final snapshot on destroy so vote data survives a destroy/apply
  # cycle (see docs/deploy.md). The suffix must be unique per destroy --
  # pass a fresh one via -var="db_final_snapshot_suffix=$(date +%Y%m%d%H%M%S)".
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-db-final-${var.final_snapshot_suffix}"

  lifecycle {
    # password: rotated out-of-band, not through this resource.
    # snapshot_identifier: create-time-only (AWS ForceNew) -- ignore so a later
    # apply without a fresh snapshot.auto.tfvars doesn't try to replace the DB.
    ignore_changes = [password, snapshot_identifier]
  }

  tags = {
    Voteball = "rds"
  }
}
