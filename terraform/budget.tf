# Cost alerting.
#
# READ THIS BEFORE EXPECTING IT TO SAVE YOU: AWS has no hard spending cap. There is no setting
# anywhere -- not here, not in the console -- that stops billing at a threshold. A budget sends
# email; it does not switch anything off. AWS Budgets *can* attach an action that applies a deny
# IAM policy, and that is deliberately not used here: cutting IAM out from under a running EKS
# cluster does not produce a clean shutdown, it produces a half-broken cluster that still bills for
# the control plane, NAT gateway and RDS while the pods flail. The real control is not emitting the
# spend in the first place -- see addon-cloudwatch.tf, where the metered parts of the CloudWatch
# add-on are turned off for exactly that reason.
#
# So this is a smoke detector, not a sprinkler. The action it expects from you is
# `./scripts/destroy.sh`.
#
# Cost: the first two budgets per account are free.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Fires partway through the month, while there is still time to tear something down.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 60
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  # The one that catches a leak early: AWS extrapolates the month-to-date run rate, so a resource
  # left running after a failed destroy trips this days before the money is actually spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }
}
