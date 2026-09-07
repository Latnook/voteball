variable "cluster_name" {
  description = "Resource name prefix for this stack."
  type        = string
}

variable "vpc_id" {
  description = "VPC the RDS security group belongs to."
  type        = string
}

variable "database_subnets" {
  description = "Isolated DB subnet ids -- no NAT or IGW route."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group. The ONLY source allowed to reach Postgres on 5432."
  type        = string
}

variable "db_username" {
  description = "Master username. RDS cannot change this on a snapshot restore, which is why the instance ignores changes to it."
  type        = string
}

variable "db_password" {
  description = "Master password. MUST match the DB_PASS seeded into Secrets Manager -- setting it here also RESETS the password on a snapshot restore, deliberately, so the two stay in sync."
  type        = string
  sensitive   = true
}

variable "db_snapshot_identifier" {
  description = "null = fresh empty DB; otherwise restore from this snapshot. scripts/find-latest-snapshot.sh picks the newest one up automatically."
  type        = string
}
