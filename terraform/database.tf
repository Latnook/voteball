# RDS for the EKS app, restored from the k3s final snapshot so votes survive the migration. Lives in
# the isolated DB subnets (no NAT/IGW route) and only accepts 5432 from the EKS node security group.
resource "aws_db_subnet_group" "app" {
  name       = "${var.cluster_name}-eks-db"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-eks-rds"
  description = "Postgres 5432 from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EKS nodes/pods"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Fixed at apply time so the final-snapshot name below is stable across plans (a bare timestamp()
# would re-evaluate every plan and show a perpetual diff). A destroy+apply cycle recreates this
# resource, so each cycle gets a distinct snapshot name and they never collide.
resource "time_static" "deploy" {}

resource "aws_db_instance" "app" {
  identifier          = "${var.cluster_name}-eks-db"
  snapshot_identifier = var.db_snapshot_identifier # null = fresh empty DB; otherwise restores votes

  # Both are required to create a database from scratch (snapshot_identifier = null), which is the
  # only path available to a fresh install with no prior snapshot. Setting password ALSO resets the
  # master password when restoring from a snapshot -- deliberate: it keeps the DB in sync with the
  # DB_PASS seeded into Secrets Manager, instead of silently keeping the snapshot's old password.
  username = var.db_username
  password = var.db_password

  instance_class         = "db.t4g.micro"
  db_subnet_group_name   = aws_db_subnet_group.app.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  storage_encrypted      = true # inherited from the encrypted snapshot; stated explicitly for clarity

  # Demo-DB trade-offs (documented in docs/security.md; a production cutover would flip these):
  #   final snapshot on destroy   -> votes survive a destroy/rebuild cycle (see skip_final_snapshot below)
  #   deletion_protection off      -> stack is torn down between sessions
  #   single-AZ, credentials reused -> cost + parallel-demo simplicity (user chose credential reuse)
  #
  # Every destroy leaves a restore point, so destroy->apply preserves votes and the stack no longer
  # depends on one hand-pinned snapshot surviving. find-latest-snapshot.sh picks the newest one up.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster_name}-eks-db-final-${formatdate("YYYYMMDDhhmmss", time_static.deploy.rfc3339)}"
  apply_immediately         = true

  # NOTE: do NOT add `lifecycle { ignore_changes = [final_snapshot_identifier] }` here. It looks like
  # harmless diff-suppression but it stops the value ever reaching state, and the provider reads
  # final_snapshot_identifier FROM STATE at destroy time -- so destroy fails with
  # "final_snapshot_identifier is required when skip_final_snapshot is false", the DB survives, and
  # its ENIs then block subnet/VPC deletion. Hit on the 2026-07-20 teardown. time_static.deploy
  # already keeps this value stable across plans, so there is no diff to suppress.

  lifecycle {
    # username is the ONE safe ignore here: RDS cannot change a master username on a snapshot
    # restore, so without this Terraform proposes replacing the whole instance whenever the restored
    # snapshot's username differs from var.db_username. Unlike final_snapshot_identifier above, this
    # attribute is not read at destroy time, so ignoring it changes nothing about teardown.
    ignore_changes = [username]
  }
}
