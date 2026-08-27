# Elastic Cloud on Kubernetes (ECK) -- the operator that reconciles the Elasticsearch and Kibana
# custom resources in charts/logging. See docs/design/2026-08-27-efk-logging-design.md.
#
# THIS IS A PLATFORM ADD-ON, NOT THE APPLICATION -- the same class as ArgoCD, ESO, external-dns and
# kube-prometheus-stack. It reaches the cluster by `terraform apply`, never by a git push. Committing
# a version bump here and walking away does nothing.
#
# WHY TERRAFORM RATHER THAN ArgoCD: the chart installs 17 CLUSTER-SCOPED objects -- 12 CRDs, 3
# ClusterRoles, 1 ClusterRoleBinding, 1 ValidatingWebhookConfiguration. Both AppProjects in
# argocd/voteball-application.yaml.tmpl set `clusterResourceWhitelist: []`, a deliberate blast-radius
# limit, so ArgoCD is structurally unable to manage this. The namespaced Elasticsearch/Kibana/Fluentd
# objects ARE eligible and live in charts/logging.
#
# WHY NOT BY HAND: a hand-run `helm install` is invisible to Terraform, so it silently disappears on
# every rebuild of this cluster -- and scripts/destroy.sh pre-uninstalls a KNOWN list of releases
# while the cluster is still healthy. An unknown release owning this operator is exactly the shape
# that hangs teardown, because the CUSTOM RESOURCES MUST GO FIRST: ECK attaches its own finalizers to
# the Elasticsearch/Kibana resources and to the Secrets they own, and only the running operator
# removes them. Uninstall the operator first and every CR sits Terminating with no controller left to
# clear it -- the same class as kubernetes_namespace.ci on 2026-08-04.
#
# NOT the ValidatingWebhookConfiguration, which is the intuitive-but-wrong explanation this comment
# used to give. Rendering eck-operator 3.5.0 shows all 16 webhooks are `failurePolicy: Ignore` on
# `operations: [CREATE, UPDATE]`: DELETE is never intercepted at all, and an unreachable webhook is
# SKIPPED rather than blocking. The stated mechanism cannot occur. The ORDER is still correct; only
# the reason was wrong.
resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = "3.5.0" # verified latest via `helm search repo elastic/eck-operator --versions` (2026-08-27)
  namespace        = "elastic-system"
  create_namespace = true

  # The operator's own StatefulSet already requests only 100m/150Mi and already runs
  # runAsNonRoot / allowPrivilegeEscalation:false / readOnlyRootFilesystem:true out of the box, so
  # there is nothing to override for this repo's container-security bar.
  #
  # helm provider v3: `set` is a LIST of attribute maps, never a `set {}` block (see versions.tf).
  set = [
    {
      # Watch only the namespace charts/logging deploys into. The default is every namespace, which
      # would have the operator reconciling CRs anywhere in the cluster. Verified against
      # `helm show values elastic/eck-operator --version 3.5.0` and by rendering the chart with this
      # value set: the operator's own config carries `namespaces: [logging]`.
      name  = "managedNamespaces[0]"
      value = "logging"
    },
  ]

  depends_on = [module.eks]
}

# ---- TLS for the Kibana route ----
#
# WHY THIS EXISTS AT ALL. charts/logging's Kibana Ingress joins ALB group `voteball` and its
# `listen-ports` includes HTTPS, but it emits NO `certificate-arn` annotation (values.yaml ships
# `certificateArn: ""` on purpose -- see below). The AWS Load Balancer Controller then falls back to
# HOST-BASED DISCOVERY: it searches ACM in this region for an ISSUED certificate whose domain or SAN
# matches the Ingress rule's host. Live ACM here holds only `latnook.com`, `voteball.latnook.com` and
# `jenkins.voteball.latnook.com`, and there is no wildcard -- so without this resource the controller
# finds nothing and errors.
#
# THAT ERROR IS NOT SCOPED TO KIBANA. A grouped Ingress is reconciled as one model for the whole
# group, so a member the controller cannot resolve a certificate for FAILS THE GROUP'S MODEL BUILD --
# stalling the ALB that also serves the public site (devops-app/voteball) and the Jenkins webhook
# (ci/jenkins-webhook). One un-certificated Ingress can therefore freeze the other two.
#
# ITS OWN CERTIFICATE, NOT A SAN ON THE APP'S -- the same call as aws_acm_certificate.jenkins in
# addon-jenkins.tf, and for the same reason: adding a SAN would change the app certificate's ARN on
# every rebuild and drag `ingress.certificateArn` (one of the ten fields scripts/sync-values-from-tf.sh
# owns) along with it. Keeping it separate leaves that field untouched.
#
# AND IT ADDS NO ELEVENTH SYNC-MANAGED FIELD. charts/logging keeps `certificateArn: ""`; discovery
# does the wiring, so nothing has to write an ARN into a chart on every rebuild. The ordering that
# makes discovery safe is the same one that gates the chart: this apply is deploy step 6 and the
# `logging` ArgoCD Application is not created until step 11, so the certificate is already ISSUED
# (aws_acm_certificate_validation below blocks the apply until it is) before the Ingress exists.
#
# It lives HERE rather than in acm.tf or a new acm-kibana.tf because addon-jenkins.tf sets the
# precedent: a host's certificate belongs in its feature's own add-on file, with the rest of that
# feature's Terraform surface. acm.tf is the app's own certificate; there is no per-host acm-*.tf
# convention in this repo to follow.
resource "aws_acm_certificate" "kibana" {
  domain_name       = "kibana.${var.app_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "kibana_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.kibana.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.primary.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks the apply until ACM reports the certificate ISSUED. Without this the apply could finish while
# the certificate is still PENDING_VALIDATION, and host-based discovery only ever considers ISSUED
# certificates -- so the ALB failure above would still happen, just later and with nothing to point at.
resource "aws_acm_certificate_validation" "kibana" {
  certificate_arn         = aws_acm_certificate.kibana.arn
  validation_record_fqdns = [for r in aws_route53_record.kibana_cert_validation : r.fqdn]
}
