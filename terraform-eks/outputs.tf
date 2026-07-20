output "cluster_name" {
  description = "EKS cluster name (for aws eks update-kubeconfig)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region."
  value       = var.aws_region
}

output "ecr_repository_urls" {
  description = "ECR repo URLs by component (push target for the CI/deploy pipeline)."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "acm_certificate_arn" {
  description = "ACM cert ARN for the ALB (Plan 3)."
  value       = aws_acm_certificate.app.arn
}

output "s3_bucket" {
  description = "Rollups/backups bucket name."
  value       = aws_s3_bucket.rollups.id
}

output "secret_arn" {
  description = "Secrets Manager secret ARN (ESO source, Plan 2b)."
  value       = aws_secretsmanager_secret.app.arn
}

output "oidc_provider_arn" {
  description = "Cluster OIDC provider ARN (for add-on IRSA roles in Plan 2b)."
  value       = module.eks.oidc_provider_arn
}

output "worker_role_arn" {
  description = "IRSA role ARN to annotate onto the devops-app:worker service account (Plan 3)."
  value       = aws_iam_role.worker.arn
}

output "backup_role_arn" {
  description = "IRSA role ARN to annotate onto the devops-app:backup service account (Plan 3)."
  value       = aws_iam_role.backup.arn
}

output "rds_endpoint" {
  description = "EKS RDS endpoint host (for the app ConfigMap DB_HOST)."
  value       = aws_db_instance.app.address
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC (set as the repo variable AWS_ROLE_ARN)."
  value       = aws_iam_role.github_actions.arn
}

output "ecr_registry" {
  description = "ECR registry host for this account/region (becomes image.registry in the Helm chart)."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "app_domain" {
  description = "Public FQDN the app is served on (becomes ingress.host in the Helm chart)."
  value       = var.app_domain
}
