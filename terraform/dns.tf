# Every ACM certificate and Route53 record this stack owns, in one file.
#
# Three certificates, one per public hostname: the app, the Jenkins webhook endpoint and Kibana.
# They are separate certificates rather than SANs on one, deliberately -- see the comment above
# aws_acm_certificate.kibana. Each is DNS-validated by writing a CNAME into the zone below, and each
# aws_acm_certificate_validation blocks the apply until AWS has actually issued the cert, so nothing
# downstream can attach an ARN that is still pending.
#
# The jenkins and kibana certs lived in addon-jenkins.tf and addon-eck.tf until 2026-09-07. Moving
# them here changed no state address -- both files are the root module either way.

# The existing public hosted zone (created outside this stack) -- used for ACM DNS validation and the
# ALB alias record. You must already own this zone in Route53; this stack never creates it.
data "aws_route53_zone" "primary" {
  name         = var.route53_zone_name
  private_zone = false
}

# ACM cert for the app FQDN, DNS-validated by writing the validation CNAME into the existing zone.
# This replaces the k3s certbot/Let's-Encrypt mechanism (and its rate limits) -- the ALB (Plan 3)
# references this cert's ARN.
resource "aws_acm_certificate" "app" {
  domain_name       = var.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.primary.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# ---- TLS for the webhook endpoint ----
# Its own certificate, NOT a SAN added to the app's. Keeping them separate means this never touches
# ingress.certificateArn, so scripts/sync-values-from-tf.sh stays at ten managed fields.
resource "aws_acm_certificate" "jenkins" {
  domain_name       = "jenkins.${var.app_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "jenkins_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.jenkins.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "jenkins" {
  certificate_arn         = aws_acm_certificate.jenkins.arn
  validation_record_fqdns = [for r in aws_route53_record.jenkins_cert_validation : r.fqdn]
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
