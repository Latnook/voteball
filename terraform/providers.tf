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

# Authenticate the helm + kubernetes providers to the live cluster using short-lived exec tokens
# (aws eks get-token) -- no long-lived kubeconfig in state. These providers can only initialize once
# the cluster exists, which is why add-ons are applied after it.
#
# There is deliberately NO `data "aws_eks_cluster_auth"` here. One was declared from the start and
# referenced by nothing -- both providers below authenticate through `exec`, which shells out to
# `aws eks get-token` on every call, so the data source's token was fetched and thrown away. Removed
# 2026-09-07.

locals {
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.compute.cluster_name, "--region", var.aws_region]
  }
}

provider "kubernetes" {
  host                   = module.compute.cluster_endpoint
  cluster_ca_certificate = base64decode(module.compute.cluster_certificate_authority_data)
  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

# NOTE the `=` on kubernetes/exec below: the helm provider is v3 (Plugin Framework), where these are
# object ATTRIBUTES, not blocks. The kubernetes provider above is still SDKv2 and keeps block syntax
# -- the two look almost identical and are deliberately different. See versions.tf.
provider "helm" {
  kubernetes = {
    host                   = module.compute.cluster_endpoint
    cluster_ca_certificate = base64decode(module.compute.cluster_certificate_authority_data)
    exec = {
      api_version = local.eks_exec.api_version
      command     = local.eks_exec.command
      args        = local.eks_exec.args
    }
  }
}
