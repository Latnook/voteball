# EKS cluster + a single managed node group on Spot. enable_irsa creates the OIDC provider that the
# hand-rolled IRSA roles (irsa.tf) federate against. enable_cluster_creator_admin_permissions grants
# the Terraform caller cluster-admin via an EKS access entry, so `kubectl get nodes` works right
# after apply without hand-editing aws-auth (the v20 module uses access entries, not the configmap).
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      # Managed node group on Spot with diversified instance types (see the node-group deviation
      # note in the plan). AL2023 is the current EKS-optimized AMI family.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "SPOT"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Tag the node group's ASG so the Plan-2b Cluster Autoscaler can discover and manage it.
      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  # Project/Environment come from the provider default_tags -- no per-module tags block needed.
}
