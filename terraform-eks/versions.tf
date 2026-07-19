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
  }
}
