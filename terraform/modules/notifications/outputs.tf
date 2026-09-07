output "sns_topic_arn" {
  description = "Milestone-alert topic the worker, Alertmanager and the CI notifier publish to."
  value       = aws_sns_topic.notifications.arn
}
