locals {
  name_prefix = "voteball"
}

resource "aws_sns_topic" "notifications" {
  name = "${local.name_prefix}-notifications"

  tags = {
    Voteball = "sns"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn                       = aws_sns_topic.notifications.arn
  protocol                        = "email"
  endpoint                        = var.notification_email
  confirmation_timeout_in_minutes = 1
  endpoint_auto_confirms          = false
}
