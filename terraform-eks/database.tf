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

resource "aws_db_instance" "app" {
  identifier             = "${var.cluster_name}-eks-db"
  snapshot_identifier    = var.db_snapshot_identifier # restores votes; master password comes FROM the snapshot
  instance_class         = "db.t4g.micro"
  db_subnet_group_name   = aws_db_subnet_group.app.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  storage_encrypted      = true # inherited from the encrypted snapshot; stated explicitly for clarity

  # Demo-DB trade-offs (documented in docs/security.md; a production cutover would flip these):
  #   skip_final_snapshot=true    -> this is a throwaway copy; the k3s snapshot is the source of truth
  #   deletion_protection off      -> stack is torn down between sessions
  #   single-AZ, credentials reused -> cost + parallel-demo simplicity (user chose credential reuse)
  skip_final_snapshot = true
  apply_immediately   = true
}
