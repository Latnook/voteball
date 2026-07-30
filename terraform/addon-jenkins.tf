# Jenkins CI, in-cluster. Replaces the retired terraform/jenkins/ EC2 stack.
#
# Design: docs/design/2026-07-30-jenkins-on-eks-design.md
#
# Jenkins is a PLATFORM add-on here, like ArgoCD and ESO, which is why it lives in this stack and is
# installed by helm_release rather than synced by ArgoCD. Consequence: changes reach the cluster by
# `terraform apply`, NOT by committing to master. That differs from charts/voteball on purpose.
#
# NOTE this stack now owns CI, reversing the old "never let the CI server be owned by the stack it
# builds for" rule. That rule protected credentials, job configuration and build history. None of
# those live here any more: credentials are in Secrets Manager, configuration is in git (JCasC), and
# build history is deliberately disposable (design doc section 2).

resource "kubernetes_namespace" "ci" {
  metadata {
    name = "ci"
    labels = {
      # Selectable by the NetworkPolicies in charts/jenkins-support.
      "kubernetes.io/metadata.name" = "ci"
    }
  }
}

# ---- IRSA: ECR push for the AGENTS. The controller gets no AWS role at all. ----
# Narrower than the EC2 instance profile it replaces, which held ECR push AND Secrets Manager read on
# one identity. Secrets Manager access now belongs to ESO alone.
data "aws_iam_policy_document" "jenkins_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:ci:jenkins"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_permissions" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken is account-wide by design
  }
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
      # GetDownloadUrlForLayer is required to IMPORT the BuildKit layer cache and to pull the
      # mirrored Trivy DB. The EC2 instance profile never needed it because that host only pushed.
      "ecr:GetDownloadUrlForLayer",
    ]
    # An ARN PATTERN, not references to the repositories. Lifted from the retired stack, where it
    # removed a cross-stack dependency; here it means the buildcache and trivy-db repos added in
    # Task 1 are already covered with no widening.
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-*"
    ]
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.cluster_name}-jenkins-irsa"
  assume_role_policy = data.aws_iam_policy_document.jenkins_trust.json
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "${var.cluster_name}-jenkins-permissions"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_permissions.json
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

# ---- Supporting cluster resources (ExternalSecret + NetworkPolicies) ----
resource "helm_release" "jenkins_support" {
  name      = "jenkins-support"
  chart     = "${path.module}/../charts/jenkins-support"
  namespace = kubernetes_namespace.ci.metadata[0].name

  set = [
    { name = "awsRegion", value = var.aws_region },
    { name = "secretName", value = aws_secretsmanager_secret.jenkins.name },
    # This VPC's real CIDR, not the 10.0.0.0/16 default baked into the chart for offline `helm
    # template` runs -- see charts/jenkins-support/values.yaml.
    { name = "vpcCidr", value = module.vpc.vpc_cidr_block },
    # charts/jenkins-support/values.yaml states every value comes from Terraform; its own default
    # exists only so `helm template` runs offline. Passing this explicitly, rather than relying on
    # that default, keeps it from drifting silently if the chart's default ever changes.
    { name = "refreshInterval", value = "1h" },
  ]

  depends_on = [helm_release.external_secrets]
}

# Single source of truth for the Jenkins chart version. It MUST drive both the URL and the
# `version` argument: while `chart` is a URL, Helm ignores `version` entirely, so two literals
# could drift apart silently -- a maintainer bumping only `version` would get a successful apply
# that installs nothing new.
locals {
  jenkins_chart_version = "5.9.45" # verified via `helm search repo jenkins/jenkins --versions` on 2026-07-30 (app v2.568.1)
}

# ---- Jenkins itself ----
resource "helm_release" "jenkins" {
  name = "jenkins"
  # A direct chart archive URL, NOT repository = "https://charts.jenkins.io" + chart = "jenkins".
  # The Helm Go SDK's chart resolver os.Stat()s the literal `chart` string against the local
  # filesystem BEFORE ever consulting `repository`, and `terraform apply` runs from inside
  # terraform/ -- which still contains terraform/jenkins/, the separate EC2 Jenkins stack this task
  # does not touch (see the "SEPARATE stack" rule in CLAUDE.md). `chart = "jenkins"` therefore
  # silently resolves to that unrelated directory instead of the Helm repo, and fails trying to
  # parse a provider cache file inside it as a chart. Pointing straight at the release archive
  # sidesteps the stat call, because the string is never a valid local path.
  #
  # This URL form exists ONLY because of that collision. Task 10 of the migration plan deletes
  # terraform/jenkins/ (the retired EC2 stack); once that lands, this should revert to
  # repository = "https://charts.jenkins.io" + chart = "jenkins", which is the form every other
  # helm_release in this stack uses.
  #
  # NOTE: `version` below does NOTHING here -- Helm's ResolveChartVersion short-circuits on an
  # absolute chart URL and never looks at `version` at all. It is kept only so `terraform plan`
  # shows the intended version in the resource diff; the URL itself is what actually pins the
  # chart, which is why both interpolate the same local.
  chart     = "https://github.com/jenkinsci/helm-charts/releases/download/jenkins-${local.jenkins_chart_version}/jenkins-${local.jenkins_chart_version}.tgz"
  version   = local.jenkins_chart_version
  namespace = kubernetes_namespace.ci.metadata[0].name

  values = [yamlencode({
    controller = {
      image = {
        registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
        repository = "${var.cluster_name}-jenkins"
        tag        = var.jenkins_image_tag
      }
      # The image already contains every plugin. Leaving this on would make a disposable controller
      # refetch them from updates.jenkins.io on every restart -- roughly daily on Spot.
      installPlugins   = false
      overwritePlugins = false

      # The controller must not build. Agents do.
      numExecutors = 0

      resources = {
        requests = { cpu = "250m", memory = "1Gi" }
        limits   = { memory = "2Gi" }
      }

      # JCasC placeholders resolve from these, projected out of the Secret ESO writes.
      containerEnvFrom = [{ secretRef = { name = "jenkins-secret" } }]
      containerEnv = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "CLUSTER_NAME", value = var.cluster_name },
        { name = "GITHUB_REPO", value = var.github_repo },
        { name = "APP_DOMAIN", value = var.app_domain },
      ]

      JCasC = {
        # FALSE, and it must stay false. The chart's default config emits its own `jenkins:` block --
        # mode, numExecutors, and a whole kubernetes cloud -- and ci/jenkins/jenkins.yaml defines the
        # same keys. JCasC treats a key defined in two files as a ConfiguratorConflictException and
        # REFUSES TO BOOT: exit code 5, "Failed to initialize Jenkins", before any probe can help.
        # Observed live on 2026-07-30 (voteball.yaml line 23 == numExecutors).
        #
        # Turning this on to "get the chart's sensible defaults" reintroduces the conflict. If the
        # controller needs something the default config provided, add it to ci/jenkins/jenkins.yaml --
        # that file is the single source of truth for this controller's configuration.
        defaultConfig = false
        configScripts = {
          "voteball" = file("${path.module}/../ci/jenkins/jenkins.yaml")
        }
      }

      # The Ingress is defined in Task 7, not here, because it must join the app's ALB group and
      # expose only one path.
      ingress = { enabled = false }

      serviceType = "ClusterIP"
    }

    serviceAccount = {
      name = "jenkins"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.jenkins.arn
      }
    }

    # Namespace-scoped Role only. The chart's default is already namespaced; asserted by
    # scripts/tests/test-jenkins-chart.sh so a future chart bump cannot widen it unnoticed.
    rbac = { create = true, readSecrets = false }

    # JENKINS_HOME is an emptyDir. See design doc section 2: three Spot reclaims in 84 hours, and an
    # EBS volume is AZ-locked, so a PVC would preserve almost nothing while adding the only failure
    # mode needing manual recovery (pod Pending forever, unable to mount).
    persistence = { enabled = false }

    agent = {
      # The pod template lives in the Jenkinsfile (that is "how to build"); this only sets defaults.
      enabled = true
      podName = "jenkins-agent"
    }
  })]

  depends_on = [
    helm_release.jenkins_support,
    aws_acm_certificate_validation.jenkins,
  ]
}
