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
  # PIN THIS, AND KEEP IT IN STANDARD SUPPORT. Extended support costs 5x ($0.50 vs $0.10/hr) and
  # nothing alerts when a version crosses over -- the bill just quadruples.
  #
  # This pin lives here rather than in voteball.tfvars ON PURPOSE: that file is gitignored, so a
  # value set there would leave the committed default disagreeing with the live cluster forever.
  # It is an engineering pin, not account identity -- unlike the region/domain/ARNs.
  #
  # Deliberately NOT restating the support table here; it goes stale (this comment claimed 1.33 was
  # STANDARD until 1.33 crossed over on 2026-07-29). Re-verify before changing:
  #   aws eks describe-cluster-versions --region <region>
  # Current window and the upgrade procedure: docs/maintenance.md.
  #
  # An in-place upgrade CANNOT skip a minor -- 1.34 -> 1.36 is two sequential applies. A fresh
  # apply against no existing cluster creates this version directly, no hops.
  description = "EKS Kubernetes minor version (pinned; keep in standard support)."
  type        = string
  default     = "1.36"
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
  # NO DEFAULT, deliberately -- this variable used to default to ["0.0.0.0/0"] and the 2026-08-23
  # Task 3 review scored it (finding T3-2). The endpoint is IAM-authenticated, so an open CIDR is not
  # an unauthenticated hole: a caller still needs valid AWS credentials plus an EKS access entry. But
  # a default nobody has to look at is a decision nobody makes, and every fork of this repo inherited
  # an internet-reachable control plane without ever being asked. Terraform now refuses to plan until
  # this is set, which is the point: the choice is cheap, but only if you are made to make it.
  #
  # Private (in-VPC) access stays enabled regardless, so in-cluster components -- ArgoCD, the Jenkins
  # CD agent, external-dns -- never traverse the public path and are unaffected by whatever is set
  # here. This variable governs laptops and anything else outside the VPC.
  #
  # OPERATIONAL COST, know this before you narrow it: a home ISP reassigns your address, and when it
  # changes EVERYTHING outside the VPC loses the cluster at once -- kubectl, terraform plan/apply,
  # deploy.sh, destroy.sh, the evidence scripts. The symptom is a connection/i-o timeout against the
  # *.eks.amazonaws.com endpoint, NOT a 403, so it reads like the cluster is down rather than like an
  # access-list miss. Run ./scripts/refresh-api-cidr.sh to rewrite this with your current address,
  # then `terraform apply`. Check that BEFORE debugging security groups, DNS or the VPC.
  #
  # Setting ["0.0.0.0/0"] here on purpose is a legitimate answer for a short-lived demo cluster and is
  # deliberately NOT rejected below -- an explicit open list is a decision; an invisible default was
  # not.
  description = "CIDRs allowed to reach the public EKS API endpoint. No default: set it in voteball.tfvars, e.g. via ./scripts/refresh-api-cidr.sh."
  type        = list(string)

  validation {
    # EKS rejects an empty list when public access is enabled, but it does so from the AWS API in the
    # middle of a billed apply, several minutes in. Catching it at plan time costs nothing.
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must name at least one CIDR while the public endpoint is enabled. Run ./scripts/refresh-api-cidr.sh to set it to your current address."
  }

  validation {
    condition     = alltrue([for c in var.cluster_endpoint_public_access_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry must be a CIDR block, not a bare address -- a single host is \"1.2.3.4/32\", not \"1.2.3.4\"."
  }
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
  description = "Email subscribed to the SNS milestone-alert topic, and to the cost budget alerts."
  type        = string
}

variable "monthly_budget_usd" {
  # Default is deliberately just above what this stack costs when it is up for a full month
  # (EKS control plane + NAT + Spot nodes + RDS + ALB is roughly $290/mo -- measured 2026-08-04 from
  # Cost Explorer, after the CloudWatch add-on cuts; it was ~$200 in the docs and never in the bill),
  # so the alert means
  # "something is wrong", not "the stack is running". Nothing enforces it -- see budget.tf.
  description = "Monthly account spend, in USD, above which budget alert emails are sent."
  type        = string
  default     = "230"
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

variable "jenkins_image_tag" {
  description = "Tag of the Jenkins controller image in ECR. Built by ./scripts/build-push-ecr.sh jenkins; bumped by hand when ci/jenkins/ changes, which is rare."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the GitHub repository Jenkins builds. Kept out of code so a fork supplies its own."
  type        = string
}
