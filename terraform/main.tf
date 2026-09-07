# Module wiring.
#
# Every child module under modules/ is instantiated here and nowhere else, so this file is the one
# place that shows how the AWS layer fits together. The cluster add-ons (addon-*.tf) are deliberately
# NOT modules -- they reference 29 values they do not define, against 3-9 for each module below, and
# a module whose job needs the word "and" to state is a boundary drawn in the wrong place.
# See docs/design/2026-09-07-terraform-module-layout-design.md section 1.

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
  vpc_id       = module.vpc.vpc_id
  azs          = var.azs

  # Two lists describing the same subnets on purpose -- the CIDRs are static and safe as for_each
  # KEYS, the ids come from the VPC module and are only safe as VALUES. See the comment above
  # aws_efs_mount_target.jenkins in the module.
  private_subnet_cidrs = local.private_subnet_cidrs
  private_subnet_ids   = module.vpc.private_subnets

  node_security_group_id = module.eks.node_security_group_id
}
