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
