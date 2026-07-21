# AWS WAF v2 in front of the ALB. Addresses docs/production-readiness.md section 2: /api/vote is
# unauthenticated, and this repo ships scripts/seed-demo-votes.py, which pushed 664 ballots through
# the public API in about two minutes. That script is the attack, written down.
#
# This does NOT make the poll un-stuffable -- nothing short of authenticating people does, which the
# project deliberately declines. The goal is "expensive enough not to be worth it".
#
# NOTE: there is deliberately no aws_wafv2_web_acl_association here. The ALB is created by the AWS
# Load Balancer Controller from the Ingress, not by Terraform, so it does not exist at apply time.
# The ACL is attached by the `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation instead, whose
# value scripts/sync-values-from-tf.sh writes into charts/voteball/values.yaml from the output below.
#
# Cost: ~$5/mo for the ACL + $1/mo per rule + $0.60 per million requests. Roughly $10/mo here.

resource "aws_wafv2_web_acl" "app" {
  name        = "${var.cluster_name}-alb"
  description = "Rate limiting and common protections for the Voteball ALB"
  scope       = "REGIONAL" # REGIONAL = ALB/API Gateway; CLOUDFRONT is a different scope entirely

  default_action {
    allow {}
  }

  # ---------------------------------------------------------------------------------------------
  # 1. The rule that actually matters: rate-limit the vote endpoint per IP.
  # ---------------------------------------------------------------------------------------------
  # The backend already enforces a salted 5-per-24h cap per address and a dedup cookie. This is the
  # network-level complement: it stops the flood before it reaches a pod, and it costs an attacker
  # far more to work around than the application check alone.
  #
  # 100 requests / 5 minutes / IP against /api/vote is generous for a human (one vote per person,
  # ever) and ruinous for a script. Deliberately not lower: shared NATs and university/corporate
  # egress put many genuine voters behind one address.
  rule {
    name     = "RateLimitVoteEndpoint"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/vote"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_name}-rate-vote"
      sampled_requests_enabled   = true
    }
  }

  # ---------------------------------------------------------------------------------------------
  # 2. A much looser site-wide ceiling, so a scraper cannot hammer /api/results either.
  # ---------------------------------------------------------------------------------------------
  rule {
    name     = "RateLimitSiteWide"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_name}-rate-sitewide"
      sampled_requests_enabled   = true
    }
  }

  # ---------------------------------------------------------------------------------------------
  # 3. Known bad inputs -- blocked. Low false-positive risk: this rule group targets request
  #    patterns that are already invalid, not merely unusual.
  # ---------------------------------------------------------------------------------------------
  rule {
    name     = "AWSKnownBadInputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ---------------------------------------------------------------------------------------------
  # 4. The AWS Common Rule Set -- deliberately in COUNT mode, NOT blocking.
  # ---------------------------------------------------------------------------------------------
  # This group is the usual source of "the site mysteriously broke for some users". It includes
  # size-restriction and body-inspection rules that a JSON POST carrying up to 3 clubs per league
  # across 8 leagues can plausibly trip, and a false positive here silently discards a genuine
  # ballot -- the exact data this project exists to collect.
  #
  # Counting first is the honest sequence: let it observe real traffic, read
  # `${var.cluster_name}-common-rules` in CloudWatch, and promote to blocking (swap `count {}` for
  # `none {}`) once it is demonstrably not matching legitimate votes. Shipping it as `block` on the
  # strength of "it is the recommended baseline" would be guessing with the ballots.
  rule {
    name     = "AWSCommonRules"
    priority = 4

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.cluster_name}-alb"
  }
}
