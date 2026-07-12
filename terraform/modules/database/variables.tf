variable "vpc_id" {
  type = string
}

variable "sg_rds_id" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "final_snapshot_suffix" {
  description = "Suffix for the RDS final snapshot identifier, e.g. a timestamp passed at destroy time so repeated destroys don't collide on snapshot names."
  type        = string
  default     = "manual"
}

variable "snapshot_identifier" {
  description = "If set, restore the DB from this snapshot instead of creating an empty one. Populated by scripts/find-latest-snapshot.sh via terraform/snapshot.auto.tfvars."
  type        = string
  default     = null
}
