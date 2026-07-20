# IRSA for Cluster Autoscaler, scoped (via the helper's cluster_autoscaler policy) to autoscaling
# actions on THIS cluster's ASG only -- discovered through the k8s.io/cluster-autoscaler/<name>=owned
# tag set on the node group in Plan 2's eks.tf.
module "autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                        = "${var.cluster_name}-cluster-autoscaler-irsa"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

# Cluster Autoscaler (Kubernetes autoscaler SIG, official): scales the managed node group 2->4 when
# pods can't schedule and back down when nodes are underused. autoDiscovery finds the ASG by the tag
# set in eks.tf. Chart 9.58.0 ships CA app v1.35.0, which is adjacent-compatible with the 1.34 cluster.
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.58.0" # verified latest via `helm search repo` on 2026-07-19 (app v1.35.0)
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.autoscaler_irsa.iam_role_arn
  }
}
