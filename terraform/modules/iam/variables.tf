variable "cluster_name" {
  description = "Resource name prefix for this stack."
  type        = string
}

variable "aws_region" {
  description = "AWS region, used to build log-group and ECR ARNs."
  type        = string
}

variable "account_id" {
  description = "AWS account id, used to build log-group and ECR ARNs."
  type        = string
}

variable "oidc_provider" {
  description = "EKS OIDC provider hostpath, e.g. oidc.eks.<region>.amazonaws.com/id/<id>. Used as the condition key prefix in every trust policy."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN -- the federated principal every role below trusts."
  type        = string
}

variable "bucket_arn" {
  description = "Rollups bucket ARN. The worker and backup roles get write access to one prefix each, never the whole bucket."
  type        = string
}

variable "sns_topic_arn" {
  description = "Milestone-alert topic. Only the worker and alertmanager roles may publish to it."
  type        = string
}
