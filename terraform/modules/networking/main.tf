# Dedicated VPC for EKS. Public subnets host the ALB + NAT GW; private subnets host nodes/pods;
# database subnets are isolated (no NAT/IGW route). Single NAT GW to save ~$35/mo -- the trade-off is
# an AZ-1a dependency for egress, acceptable for a course project.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-eks-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = var.public_subnet_cidrs
  private_subnets  = var.private_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

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
