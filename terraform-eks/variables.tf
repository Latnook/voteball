variable "aws_region" {
  description = "AWS region for all EKS resources."
  type        = string
  default     = "il-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name; also the resource name prefix for this stack."
  type        = string
  default     = "voteball"
}

variable "cluster_version" {
  # PIN THIS. Extended support costs 5x standard ($0.50 vs $0.10/hr).
  # Verified 2026-07-19 via `aws eks describe-cluster-versions --region il-central-1`:
  # STANDARD support = 1.33/1.34/1.35/1.36 (1.36 default); 1.30/1.31/1.32 already EXTENDED.
  # 1.34 chosen: standard support past the early-Aug-2026 deadline (~Dec 2026), mature enough for
  # all Plan-2b add-ons. Re-confirm the tier at apply time if this sits unbuilt for weeks.
  description = "EKS Kubernetes minor version (pinned; keep in standard support)."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated EKS VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones (>=2 for EKS/ALB)."
  type        = list(string)
  default     = ["il-central-1a", "il-central-1b"]
}

variable "node_instance_types" {
  # Multiple types diversify Spot capacity pools (resilience without On-Demand fallback).
  # t3.large sized for the Plan-2b add-on stack (Prometheus/Grafana/ArgoCD/controllers), not just the app.
  description = "Instance types for the managed Spot node group."
  type        = list(string)
  default     = ["t3.large", "t3a.large"]
}

variable "node_min_size" {
  description = "Node group min size. min:2 buys real HA, functioning PDBs, and a drain destination."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Node group max size (Cluster Autoscaler, added in Plan 2b, scales 2->4 on load)."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Node group desired size at creation."
  type        = number
  default     = 2
}

variable "cluster_endpoint_public_access_cidrs" {
  # The EKS API endpoint is public so kubectl works from a laptop/CI, but it is IAM-authenticated:
  # a caller still needs valid AWS creds + an EKS access entry to do anything. Defaulting to
  # 0.0.0.0/0 for demo convenience; SET THIS to your operator/CI CIDR(s) to lock the endpoint down.
  # Private (in-VPC) access stays enabled regardless, so in-cluster components use the private path.
  description = "CIDRs allowed to reach the public EKS API endpoint. Restrict for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_domain" {
  # No default: this is your domain, not the project's. Set it in voteball-eks.tfvars.
  description = "Public FQDN the ACM cert is issued for and the ALB serves (e.g. voteball.example.com)."
  type        = string
}

variable "route53_zone_name" {
  # Must be a hosted zone you already own; this stack looks it up, never creates it.
  # app_domain has to sit inside it -- e.g. app_domain=voteball.example.com, zone=example.com.
  description = "Existing Route53 public hosted zone containing app_domain, with trailing dot (e.g. example.com.)."
  type        = string
}

variable "notification_email" {
  description = "Email subscribed to the SNS milestone-alert topic."
  type        = string
}

variable "db_username" {
  # Only applied when creating a fresh database. RDS does not allow changing the master username on a
  # snapshot restore, so aws_db_instance.app ignores changes to it (see database.tf).
  description = "RDS master username (fresh databases only; ignored when restoring from a snapshot)."
  type        = string
  default     = "postgres"
}

variable "db_password" {
  # No default, deliberately. This also RESETS the master password when restoring from a snapshot,
  # which is what keeps it in sync with the DB_PASS seeded into Secrets Manager by
  # scripts/seed-eks-secret.sh -- otherwise a restored DB keeps the old snapshot's password and the
  # app cannot connect.
  description = "RDS master password. Must match the DB_PASS you seed into Secrets Manager."
  type        = string
  sensitive   = true
}

variable "db_snapshot_identifier" {
  # Restore votes from the k3s final snapshot. Set to null for a fresh empty DB instead.
  description = "RDS snapshot to restore the EKS database from (null = fresh empty DB)."
  type        = string
  # null, NOT a pinned identifier: scripts/find-latest-snapshot.sh writes the real value into
  # terraform-eks/snapshot.auto.tfvars before every apply. A hardcoded default silently hard-fails
  # ("DBSnapshot not found") the moment that one snapshot is pruned.
  default = null
}
