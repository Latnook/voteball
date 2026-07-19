# IRSA for external-dns, scoped to the latnook.com hosted zone only (the helper's external_dns policy
# grants route53:ChangeResourceRecordSets on the given zone ARNs + the read actions it needs).
module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                     = "${var.cluster_name}-external-dns-irsa"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.primary.zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

# external-dns (Kubernetes SIG): reads the Ingress hostname annotation and manages the Route53 alias
# to the ALB. policy=upsert-only so it never deletes records it didn't create; txtOwnerId scopes
# ownership so multiple clusters can't fight over the same records.
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.21.1" # verified latest via `helm search repo` on 2026-07-19 (app v0.21.0)
  namespace  = "kube-system"

  set {
    name  = "provider"
    value = "aws"
  }
  set {
    name  = "aws.region"
    value = var.aws_region
  }
  set {
    name  = "domainFilters[0]"
    value = "latnook.com"
  }
  set {
    name  = "policy"
    value = "upsert-only"
  }
  set {
    name  = "txtOwnerId"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_irsa.iam_role_arn
  }
}
