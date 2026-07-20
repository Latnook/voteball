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
# to the ALB. policy=sync so teardown removes the records it created (ownership TXT gates what it may
# touch); txtOwnerId scopes ownership so multiple clusters can't fight over the same records.
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
  # sync (not upsert-only): on teardown the Ingress is deleted BEFORE terraform destroy, letting
  # external-dns remove the A/AAAA/TXT records it created. With upsert-only they survived, leaving
  # voteball.latnook.com resolving to a de-provisioned ALB until the next deploy.
  #
  # Deletion is bounded by the default txt registry + txtOwnerId below: external-dns only touches
  # records carrying an ownership TXT that names this cluster
  # ("heritage=external-dns,external-dns/owner=voteball,..."). The zone's apex MX/NS/SOA, the
  # ProtonMail verification + DKIM records, and _dmarc carry no such TXT, so they are not eligible
  # for deletion. Verified against the live zone on 2026-07-20 before this was enabled.
  set {
    name  = "policy"
    value = "sync"
  }

  # React to Ingress add/delete events immediately instead of only on the 1-minute poll (the chart
  # default is triggerLoopOnEvent=false). Without this, teardown deletes the Ingress and then destroys
  # external-dns before its next tick, so the records are never cleaned up -- observed on the
  # 2026-07-20 teardown, where voteball.latnook.com survived pointing at a dead ALB.
  # This narrows the race but does not close it; scripts/cleanup-stale-dns.sh is the deterministic
  # backstop that destroy.sh runs regardless.
  set {
    name  = "triggerLoopOnEvent"
    value = "true"
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
