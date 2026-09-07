variable "cluster_name" {
  description = "Resource name prefix for this stack."
  type        = string
}

variable "account_id" {
  description = "AWS account id, used to make the rollups bucket name globally unique."
  type        = string
}

variable "vpc_id" {
  description = "VPC the EFS security group belongs to."
  type        = string
}

variable "azs" {
  description = "Availability zones, in the same order as private_subnet_cidrs. Used only as the map KEY for the EFS mount targets, so their addresses read as az names."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    STATIC list, deliberately not derived from the VPC module.

    aws_efs_mount_target.jenkins keys its for_each on the index of this list. Only for_each VALUES
    may be unknown at plan time -- KEYS may not -- so sourcing them from the VPC module's outputs
    fails a from-scratch plan with "Invalid for_each argument". It plans fine against a live VPC and
    breaks only the next rebuild from empty state, which is the worst possible failure schedule.
    Hit for real on the 2026-08-05 rebuild; same trap the ecr_cache lifecycle policy records.
  EOT
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnet ids for the EFS mount targets. Safe to take from the VPC module: these are for_each VALUES, which may be unknown at plan time."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group -- the only source allowed to reach EFS on 2049."
  type        = string
}
