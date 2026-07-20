provider "aws" {
  region = var.aws_region

  # default_tags stamps every taggable resource in this stack (including those created by the
  # community VPC/EKS modules) without repeating tags per-resource. environment=dev labels this
  # whole stack as the "dev" environment -- a separate root module from the k3s stack, NOT a
  # Terraform workspace (workspaces share one config; these are genuinely different infra).
  # Flip Environment to "prod" and re-apply to relabel in place (tags-only update, nothing recreated).
  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = "dev"
    }
  }
}

# Account + partition lookups reused by ARN construction (S3 bucket name, IRSA policies).
data "aws_caller_identity" "current" {}

# The existing public hosted zone (created outside this stack) -- used for ACM DNS validation and the
# ALB alias record. You must already own this zone in Route53; this stack never creates it.
data "aws_route53_zone" "primary" {
  name         = var.route53_zone_name
  private_zone = false
}
