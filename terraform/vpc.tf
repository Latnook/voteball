# Dedicated VPC for EKS (the k3s stack uses the default VPC; this one is isolated).
# Public subnets host the ALB + NAT GW; private subnets host nodes/pods; database subnets are
# isolated (no NAT/IGW route) for a future RDS move. Single NAT GW to save ~$35/mo -- trade-off is
# an AZ-1a dependency for egress, acceptable for a course project.
# The private subnet CIDRs are a named local rather than an inline list because addon-efs.tf has to
# iterate them too. It needs one EFS mount target per private subnet, and the obvious source for that
# -- module.vpc.private_subnets -- is an output whose VALUES do not exist until the subnets do. Using
# it as a for_each key fails a from-scratch plan with "Invalid for_each argument". This list is static
# config, so iterating it keeps the keys known at plan time. Same rule as ecr.tf:70.
locals {
  private_subnet_cidrs = ["10.0.32.0/20", "10.0.48.0/20"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-eks-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = ["10.0.0.0/20", "10.0.16.0/20"]
  private_subnets  = local.private_subnet_cidrs
  database_subnets = ["10.0.64.0/24", "10.0.65.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS/ALB subnet discovery tags: public subnets host internet-facing LBs, private host internal.
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  # Project/Environment come from the provider default_tags; only the functional EKS discovery tag
  # is set here.
  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
