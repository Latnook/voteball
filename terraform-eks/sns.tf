# Milestone-alert topic (the worker publishes here on vote milestones). This EKS stack owns the
# topic going forward; the retired k3s stack created an identically-named one, so do not run both
# stacks at once (the k3s stack is torn down). Mirrors the k3s notifications module.
resource "aws_sns_topic" "notifications" {
  name = "${var.cluster_name}-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
