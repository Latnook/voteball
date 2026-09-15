# EKS cluster + a single managed node group on Spot. enable_irsa creates the OIDC provider that
# modules/iam's hand-rolled roles federate against. enable_cluster_creator_admin_permissions grants
# the Terraform caller cluster-admin via an EKS access entry, so `kubectl get nodes` works right
# after apply without hand-editing aws-auth (the v20 module uses access entries, not the configmap).

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  # Public endpoint for kubectl access, scoped to a REQUIRED allow-list -- the variable has no
  # default, so a plan fails until voteball.tfvars names a CIDR (./scripts/refresh-api-cidr.sh writes
  # your current one). Private in-VPC access stays on by
  # module default, so in-cluster components never traverse the public path. Secrets are KMS
  # envelope-encrypted and control-plane audit logging (api/audit/authenticator) is on, both by
  # module default -- see docs/security.md.
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.cluster_endpoint_public_access_cidrs
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  # Turn on the VPC CNI network-policy agent so Kubernetes NetworkPolicies (Plan 3b) are ENFORCED,
  # not just accepted-and-ignored. OVERWRITE adopts the EKS-default vpc-cni addon already running.
  #
  # ALL THREE networking add-ons are declared, and vpc-cni + kube-proxy are `before_compute`. That is
  # not optional under eks v21: it hardcodes bootstrap_self_managed_addons = false, so a NEW cluster
  # gets no CNI, no kube-proxy and no CoreDNS unless they are listed here -- and an add-on without
  # before_compute is created AFTER the node group, which waits for its nodes to be Ready, which
  # they never are without a CNI ("cni plugin not initialized"). The 2026-09-15 rebuild, the first on
  # v21, sat 26+ minutes in that deadlock. The in-place upgrade earlier the same day could not show
  # it: the existing cluster already had all three, and the flag sits in the module's ignore_changes.
  addons = {
    vpc-cni = {
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
      # v21 defaults this to true, which would upgrade the running CNI as a side effect of a module
      # upgrade. An add-on version change should be its own decision, not a default.
      most_recent = false
    }
    kube-proxy = {
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      most_recent                 = false
    }
    # After compute: CoreDNS is a Deployment and needs Ready nodes to schedule onto.
    coredns = {
      resolve_conflicts_on_create = "OVERWRITE"
      most_recent                 = false
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

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

      # Explicitly empty, not omitted. Omitted, the module sends null, AWS stores {}, and every plan
      # after a rebuild opened with "Objects have changed outside of Terraform: + labels = {}".
      labels = {}

      # v20 behaviour, pinned. eks v21 changed three node-group defaults, and two of them alter the
      # launch template or AMI release, which REPLACES every node: IMDS hop limit 2 -> 1,
      # use_latest_ami_release_version false -> true, enable_monitoring true -> false. Adopting any of
      # them is worth doing deliberately, with a planned node rollout -- not as a module-upgrade side
      # effect. (Hop limit 1 is the more secure setting: it stops pods reading the node's IMDS role.)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }
      use_latest_ami_release_version = false
      enable_monitoring              = true

      # Tag the node group's ASG so the Plan-2b Cluster Autoscaler can discover and manage it.
      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  # Project/Environment come from the provider default_tags -- no per-module tags block needed.
}
