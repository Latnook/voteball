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
# set in eks.tf. CA is the one add-on whose APP version tracks the Kubernetes minor, so re-check it
# before any cluster_version bump -- and note it declares no `kubeVersion`, so the usual chart
# compatibility check cannot catch a mismatch. Read the app column instead:
#   helm search repo autoscaler/cluster-autoscaler --versions
# VERSION SKEW (2026-07-30): chart 9.59.0 is the newest and pins app v1.35.0, but the cluster is on
# 1.36. Upstream HAS released CA 1.36 -- only the chart lags -- so image.tag below overrides the
# chart's default to match the cluster exactly.
#
# The risk this carries: the chart's ClusterRole and container args are generated for 1.35, so if
# 1.36 watches a resource the chart does not grant, CA fails `forbidden` at startup. That surfaces
# immediately in `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler`.
# REVERT = delete the image.tag set block below and re-apply; the chart default (v1.35.0) is a
# supported N-1 configuration. DROP the override once a chart ships app 1.36 -- keeping it after that
# pins the image against a chart that would otherwise manage it.
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.59.0" # verified latest via `helm search repo` on 2026-07-30 (chart default app v1.35.0)
  namespace  = "kube-system"

  set = [
    # Override the chart's v1.35.0 default to match the 1.36 cluster. See the VERSION SKEW note above.
    {
      name  = "image.tag"
      value = "v1.36.1"
    },
    {
      name  = "autoDiscovery.clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "awsRegion"
      value = var.aws_region
    },
    {
      name  = "rbac.serviceAccount.name"
      value = "cluster-autoscaler"
    },
    {
      name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.autoscaler_irsa.iam_role_arn
    },
  ]
}
