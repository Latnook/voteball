# IRSA role for the ALB controller. The community helper (terraform-aws-modules/iam, same maintainers
# as the vpc/eks modules) attaches AWS's OWN published load-balancer-controller policy
# (attach_load_balancer_controller_policy) -- the authoritative least-privilege definition for this
# controller, tracked across controller versions so we don't hand-transcribe ~150 lines of JSON.
module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-alb-controller-irsa"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# AWS Load Balancer Controller (AWS, official eks-charts): reconciles Kubernetes Ingress objects into
# real ALBs. Plan 3's app Ingress depends on this being present.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.2" # verified latest via `helm search repo` on 2026-07-19 (app v3.4.2)
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  # Let the chart create the SA, annotated with the IRSA role ARN.
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_irsa.iam_role_arn
  }
}
