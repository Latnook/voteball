# State-address migration for the 2026-09-07 module layout.
#
# These blocks re-point EXISTING state entries at their new addresses. Without them Terraform reads
# each relocation as "destroy the old resource, create a new one" -- and reports that as an ordinary
# plan, not as an error. On a live stack that means destroying the database. `terraform plan`
# printing "No changes." is the only thing that distinguishes a correct move from a destructive one.
#
# WHY THIS FILE IS AT THE ROOT AND NOT IN EACH MODULE: `from` is resolved relative to the module the
# block is written in. A block inside modules/foo/ saying `from = aws_thing.x` means
# module.foo.aws_thing.x -- the DESTINATION, not the source -- so Terraform rejects it with "Moved
# object still exists". A move from the root into a child module can only be declared by the caller.
# (A moved.tf inside a module is still the right place for moves WITHIN that module, e.g. renaming a
# resource the module has always owned. There are none of those here.)
#
# This file stays until the next `terraform apply` consumes it, after which state already holds the
# new addresses and every block becomes a no-op. Do not delete it before that apply has run.
# See docs/design/2026-09-07-terraform-module-layout-design.md section 3.

# ---- modules/notifications ----
moved {
  from = aws_sns_topic.notifications
  to   = module.notifications.aws_sns_topic.notifications
}

moved {
  from = aws_sns_topic_subscription.email
  to   = module.notifications.aws_sns_topic_subscription.email
}

moved {
  from = aws_budgets_budget.monthly
  to   = module.notifications.aws_budgets_budget.monthly
}

# ---- modules/storage ----
# One block per address covers every for_each instance, so the 5 app repos, 2 cache repos and
# 2 mount targets need one block each rather than nine.

moved {
  from = aws_s3_bucket.rollups
  to   = module.storage.aws_s3_bucket.rollups
}

moved {
  from = aws_s3_bucket_public_access_block.rollups
  to   = module.storage.aws_s3_bucket_public_access_block.rollups
}

moved {
  from = aws_s3_bucket_versioning.rollups
  to   = module.storage.aws_s3_bucket_versioning.rollups
}

moved {
  from = aws_ecr_repository.app
  to   = module.storage.aws_ecr_repository.app
}

moved {
  from = aws_ecr_repository.cache
  to   = module.storage.aws_ecr_repository.cache
}

moved {
  from = aws_ecr_lifecycle_policy.app
  to   = module.storage.aws_ecr_lifecycle_policy.app
}

moved {
  from = aws_ecr_lifecycle_policy.cache
  to   = module.storage.aws_ecr_lifecycle_policy.cache
}

moved {
  from = aws_efs_file_system.jenkins
  to   = module.storage.aws_efs_file_system.jenkins
}

moved {
  from = aws_efs_mount_target.jenkins
  to   = module.storage.aws_efs_mount_target.jenkins
}

moved {
  from = aws_security_group.efs
  to   = module.storage.aws_security_group.efs
}

moved {
  from = aws_vpc_security_group_ingress_rule.efs_nfs
  to   = module.storage.aws_vpc_security_group_ingress_rule.efs_nfs
}

# ---- modules/iam ----
# The last four came from addon-jenkins.tf, not irsa.tf: all hand-rolled IRSA now lives in one
# module. module.jenkins_cd_irsa (community) deliberately stayed behind -- design doc section 3a.

moved {
  from = aws_iam_role.worker
  to   = module.iam.aws_iam_role.worker
}

moved {
  from = aws_iam_role_policy.worker
  to   = module.iam.aws_iam_role_policy.worker
}

moved {
  from = aws_iam_role.backup
  to   = module.iam.aws_iam_role.backup
}

moved {
  from = aws_iam_role_policy.backup
  to   = module.iam.aws_iam_role_policy.backup
}

moved {
  from = aws_iam_role.grafana
  to   = module.iam.aws_iam_role.grafana
}

moved {
  from = aws_iam_role_policy.grafana
  to   = module.iam.aws_iam_role_policy.grafana
}

moved {
  from = aws_iam_role.alertmanager
  to   = module.iam.aws_iam_role.alertmanager
}

moved {
  from = aws_iam_role_policy.alertmanager
  to   = module.iam.aws_iam_role_policy.alertmanager
}

moved {
  from = aws_iam_role.jenkins
  to   = module.iam.aws_iam_role.jenkins
}

moved {
  from = aws_iam_role_policy.jenkins
  to   = module.iam.aws_iam_role_policy.jenkins
}

moved {
  from = aws_iam_policy.jenkins_cd_ecr_read
  to   = module.iam.aws_iam_policy.jenkins_cd_ecr_read
}

moved {
  from = aws_iam_policy.jenkins_cd_notify
  to   = module.iam.aws_iam_policy.jenkins_cd_notify
}
