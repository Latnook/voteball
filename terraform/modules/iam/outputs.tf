# Hand-rolled IRSA roles. The community `module.*_irsa` instances that serve individual add-ons stay
# beside those add-ons and are NOT re-exported here -- see the design doc, section 3a.

output "worker_role_arn" {
  description = "Annotated onto devops-app:worker. SNS publish + S3 snapshots/ prefix."
  value       = aws_iam_role.worker.arn
}

output "backup_role_arn" {
  description = "Annotated onto devops-app:backup. S3 backups/ prefix only, no SNS."
  value       = aws_iam_role.backup.arn
}

output "grafana_role_arn" {
  description = "Annotated onto the Grafana service account for the CloudWatch datasource."
  value       = aws_iam_role.grafana.arn
}

output "alertmanager_role_arn" {
  description = "Annotated onto Alertmanager for SNS publish."
  value       = aws_iam_role.alertmanager.arn
}

output "jenkins_role_arn" {
  description = "Annotated onto the ci:jenkins-agent service account. ECR push. The CONTROLLER carries no AWS role at all."
  value       = aws_iam_role.jenkins.arn
}

output "jenkins_cd_ecr_read_policy_arn" {
  description = "Attached to the CD agent role: read-only on the four APP repos, never the controller image."
  value       = aws_iam_policy.jenkins_cd_ecr_read.arn
}

output "jenkins_cd_notify_policy_arn" {
  description = "Attached to the CD agent role: SNS publish for the NEEDS A HUMAN branches."
  value       = aws_iam_policy.jenkins_cd_notify.arn
}
