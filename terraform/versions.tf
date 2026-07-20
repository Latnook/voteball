terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.0 (NOT the k3s stack's ~> 6.0): terraform-aws-modules/eks v20 caps the AWS provider at
      # < 6.0.0, so v5 is required here. Independent stack = independent lock, so the version skew
      # with the k3s stack is harmless. v5 covers everything this stack + Plan 2b/3 use.
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17" # 2.x keeps the nested `kubernetes {}` block used in providers-k8s.tf (v3 changed syntax)
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12" # time_static: stable timestamp for the RDS final-snapshot name
    }
  }
}
