output "app_public_ip" {
  value = module.compute.public_ip
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "sns_topic_arn" {
  value = module.notifications.topic_arn
}
