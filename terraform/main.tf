# Module wiring.
#
# Every child module under modules/ is instantiated here and nowhere else, so this file is the one
# place that shows how the AWS layer fits together. The cluster add-ons (addon-*.tf) are deliberately
# NOT modules -- they reference 29 values they do not define, against 3-9 for each module below, and
# a module whose job needs the word "and" to state is a boundary drawn in the wrong place.
# See docs/design/2026-09-07-terraform-module-layout-design.md section 1.

# The subnet CIDRs live here, not inside modules/networking, because TWO modules read the private
# list: networking turns it into subnets, and storage keys its EFS mount-target for_each on it.
# A for_each KEY may not be unknown at plan time, so both must read one static list rather than the
# VPC module's outputs -- see the comment above aws_efs_mount_target.jenkins in modules/storage.
locals {
  public_subnet_cidrs   = ["10.0.0.0/20", "10.0.16.0/20"]
  private_subnet_cidrs  = ["10.0.32.0/20", "10.0.48.0/20"]
  database_subnet_cidrs = ["10.0.64.0/24", "10.0.65.0/24"]
}

module "networking" {
  source = "./modules/networking"

  cluster_name          = var.cluster_name
  vpc_cidr              = var.vpc_cidr
  azs                   = var.azs
  public_subnet_cidrs   = local.public_subnet_cidrs
  private_subnet_cidrs  = local.private_subnet_cidrs
  database_subnet_cidrs = local.database_subnet_cidrs
}

module "compute" {
  source = "./modules/compute"

  cluster_name                         = var.cluster_name
  cluster_version                      = var.cluster_version
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  vpc_id     = module.networking.vpc_id
  subnet_ids = module.networking.private_subnets

  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}

module "notifications" {
  source = "./modules/notifications"

  cluster_name       = var.cluster_name
  notification_email = var.notification_email
  monthly_budget_usd = var.monthly_budget_usd
}

module "storage" {
  source = "./modules/storage"

  cluster_name = var.cluster_name
  account_id   = data.aws_caller_identity.current.account_id
  vpc_id       = module.networking.vpc_id
  azs          = var.azs

  # Two lists describing the same subnets on purpose -- the CIDRs are static and safe as for_each
  # KEYS, the ids come from the VPC module and are only safe as VALUES. See the comment above
  # aws_efs_mount_target.jenkins in the module.
  private_subnet_cidrs = local.private_subnet_cidrs
  private_subnet_ids   = module.networking.private_subnets

  node_security_group_id = module.compute.node_security_group_id
}

module "iam" {
  source = "./modules/iam"

  cluster_name      = var.cluster_name
  aws_region        = var.aws_region
  account_id        = data.aws_caller_identity.current.account_id
  oidc_provider     = module.compute.oidc_provider
  oidc_provider_arn = module.compute.oidc_provider_arn

  # Least privilege is expressed by what is NOT passed: the roles get one bucket and one topic,
  # and scope themselves to a single prefix within the bucket.
  bucket_arn    = module.storage.bucket_arn
  sns_topic_arn = module.notifications.sns_topic_arn
}

module "database" {
  source = "./modules/database"

  cluster_name           = var.cluster_name
  vpc_id                 = module.networking.vpc_id
  database_subnets       = module.networking.database_subnets
  node_security_group_id = module.compute.node_security_group_id

  db_username            = var.db_username
  db_password            = var.db_password
  db_snapshot_identifier = var.db_snapshot_identifier
}
