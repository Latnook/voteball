output "bucket_id" {
  description = "Rollups/backups bucket name."
  value       = aws_s3_bucket.rollups.id
}

output "bucket_arn" {
  description = "Rollups/backups bucket ARN, for the worker and backup IRSA policies."
  value       = aws_s3_bucket.rollups.arn
}

output "ecr_repository_urls" {
  description = "ECR repo URLs by component (push target for the CI/deploy pipeline)."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "efs_file_system_id" {
  description = "Jenkins-home filesystem id, consumed by the efs-sc StorageClass."
  value       = aws_efs_file_system.jenkins.id
}
