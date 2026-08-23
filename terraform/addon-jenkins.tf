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
  # This is the FIRST kubernetes-provider resource to touch a brand-new cluster -- every other
  # in-cluster object here arrives via helm_release, which lands later in the graph. Without an
  # explicit dependency its only ordering constraint is the provider config, so Terraform schedules
  # it as soon as the cluster API answers, which can be BEFORE the EKS access entry granting the
  # caller admin has propagated. The 2026-08-03 rebuild hit exactly that:
  #   Error: namespaces is forbidden: User ".../cli-admin" cannot create resource "namespaces"
  # -- after ~13 minutes of applying, with every helm_release add-on already installed, so it reads
  # like a permissions bug rather than a race. Waiting on the whole module covers the access entry
  # and its policy association.
  depends_on = [module.eks]

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
#
# Bound to the chart's AGENT service account (system:serviceaccount:ci:jenkins-agent), NOT the
# controller's "jenkins". The Jenkins chart's `serviceAccount` block is the CONTROLLER's SA; putting
# the role-arn annotation there (an earlier version of this file did) gave the controller itself ECR
# push to every voteball-* repo, contradicting design doc section 7 ("Jenkins controller: none"). The
# agent pod template in ci/jenkins/jenkins.yaml runs as `serviceAccountName: jenkins-agent` to pick
# this role up via IRSA; the controller's own SA carries no annotation at all.
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
      values   = ["system:serviceaccount:ci:jenkins-agent"]
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

# ---- IRSA: ECR read-only for the CD AGENT. ----
#
# The CD pipeline's AWS identity. READ-ONLY on the four application repositories, and nothing else.
#
# Its single purpose is the Input Validation stage proving a requested tag really is in ECR before
# anything is committed to master. It cannot push, cannot delete, and holds no other AWS permission.
data "aws_iam_policy_document" "jenkins_cd_ecr_read" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    # The FOUR APP REPOS ONLY -- deliberately not local.ecr_repos, which also contains
    # "jenkins" (the controller image). CD validates application image tags and has no
    # business reading the controller's repository. Keep this list in step with the
    # ECR_REPOS value in Jenkinsfile-ci and Jenkinsfile-cd.
    resources = [
      for r in ["backend", "worker", "nginx", "backup"] :
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-${r}"
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action does not support resource-level permissions.
  }
}

resource "aws_iam_policy" "jenkins_cd_ecr_read" {
  name   = "${var.cluster_name}-jenkins-cd-ecr-read"
  policy = data.aws_iam_policy_document.jenkins_cd_ecr_read.json
}

# ---- CD failure notifications ----
# Task 4 review finding P3: "a rollback action is not a reliable notification mechanism by itself".
# It is exactly right. The pipeline's worst outcome is the NEEDS A HUMAN branch -- a deploy failed,
# the automatic rollback was refused because this build IS already a rollback (ROLLBACK_DEPTH >= 1),
# and production is left running a version nobody chose. That state was announced only by a red build
# in a UI reachable through `kubectl port-forward`, on a controller that is reclaimed by Spot roughly
# daily. Nothing pushed it anywhere a person would see.
#
# sns:Publish on the EXISTING notifications topic, and nothing else. Deliberately not a second topic:
# the email subscription on this one is already confirmed (docs/eks/evidence), so reusing it means the
# alert path is proven the moment this applies, rather than being one more thing that has never
# actually delivered a message.
#
# This is the ONLY write permission the CD agent has anywhere in AWS. Its ECR access stays read-only
# and its Kubernetes Role stays read-only -- ArgoCD is still the only thing that can change the
# cluster. Publishing a message to a topic cannot deploy, delete or modify anything.
data "aws_iam_policy_document" "jenkins_cd_notify" {
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
  }
}

resource "aws_iam_policy" "jenkins_cd_notify" {
  name   = "${var.cluster_name}-jenkins-cd-notify"
  policy = data.aws_iam_policy_document.jenkins_cd_notify.json
}

module "jenkins_cd_irsa" {
  # Submodule path, matching every other IRSA role in this stack (addon-alb.tf,
  # addon-eso.tf, addon-external-dns.tf ...). The registry-root form
  # "terraform-aws-modules/iam-role-for-service-accounts-eks/aws" does not exist and fails
  # at `terraform init`.
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-jenkins-cd"

  role_policy_arns = {
    read   = aws_iam_policy.jenkins_cd_ecr_read.arn
    notify = aws_iam_policy.jenkins_cd_notify.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["ci:jenkins-cd-agent"]
    }
  }
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
    # The EKS cluster's Service CIDR, not this VPC's -- a separate, cluster-internal range the API
    # server's ClusterIP lives on. Read from the module rather than hardcoded in the chart, so a
    # fork (or a future cluster with a non-default service CIDR) is not silently broken by a value
    # baked into charts/jenkins-support/values.yaml only as an offline-`helm template` default.
    { name = "serviceCidr", value = module.eks.cluster_service_cidr },
    # charts/jenkins-support/values.yaml states every value comes from Terraform; its own default
    # exists only so `helm template` runs offline. Passing this explicitly, rather than relying on
    # that default, keeps it from drifting silently if the chart's default ever changes.
    { name = "refreshInterval", value = "1h" },
    # The webhook Ingress's cert and host. Its own certificate, not a SAN on the app's -- see the
    # comment on aws_acm_certificate.jenkins above.
    { name = "certificateArn", value = aws_acm_certificate_validation.jenkins.certificate_arn },
    { name = "host", value = "jenkins.${var.app_domain}" },
    # The CD agent's IRSA role (ECR read-only, see jenkins_cd_irsa above) and the namespace it is
    # allowed to read via the Role in charts/jenkins-support/templates/rbac.yaml.
    #
    # appNamespace reads the namespace RESOURCE rather than the literal "devops-app" on purpose. The
    # chart puts a Role and RoleBinding in that namespace, so this release cannot be installed before
    # it exists -- and a literal string creates no dependency edge, which is exactly how this came to
    # fail every from-scratch apply until 2026-08-05 (see terraform/namespaces.tf). Referencing the
    # resource makes Terraform order the two itself, so the constraint cannot be lost to a later edit
    # the way an explicit depends_on entry can.
    { name = "cdRoleArn", value = module.jenkins_cd_irsa.iam_role_arn },
    { name = "appNamespace", value = kubernetes_namespace.devops_app.metadata[0].name },
    # The PUBLIC subnet CIDRs, where the ALB's ENIs live. The ingress rule that admits the load
    # balancer is scoped to these rather than to the whole VPC -- pods get VPC addresses from the
    # PRIVATE subnets, so the old vpcCidr rule admitted every pod in the cluster to the controller.
    { name = "albSubnetCidrs[0]", value = module.vpc.public_subnets_cidr_blocks[0] },
    { name = "albSubnetCidrs[1]", value = module.vpc.public_subnets_cidr_blocks[1] },
    # TRUE now that the controller image serves /prometheus. The `prometheus` plugin ships in a
    # controller image rebuilt from ci/jenkins/plugins.txt, and jenkins_image_tag (in the gitignored
    # terraform/voteball.tfvars) now points at that rebuilt image -- confirmed to contain
    # prometheus.jpi (`ls /usr/share/jenkins/ref/plugins/` on the built image) before this flag was
    # flipped. It was FALSE only while that was untrue: creating the ServiceMonitor against an image
    # with no such plugin would have had Prometheus scrape a target that 404s forever, tripping the
    # cluster's default TargetDown rule after 10 minutes and paging SNS every 12 hours, permanently,
    # for a target nobody could fix without a separate image build.
    { name = "serviceMonitor.enabled", value = "true" },
  ]

  depends_on = [
    helm_release.external_secrets,
    # jenkins_support renders a ServiceMonitor (serviceMonitor.enabled is true above), and that CRD
    # comes from this release (kube-prometheus-stack's operator). Without this edge, a from-scratch
    # `deploy.sh` rebuild can create the two releases in parallel and jenkins_support's ServiceMonitor
    # apply fails with `no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"`,
    # aborting a billed apply part-way through. Load-bearing now, not preparation for later --
    # do not remove it because it looks like dead-code ordering for a disabled feature.
    helm_release.kube_prometheus_stack,
  ]
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
  # The conventional form, matching every other helm_release in this stack.
  #
  # This used to be a direct .tgz URL, because the Helm Go SDK's chart resolver os.Stat()s the
  # literal `chart` string against the local filesystem BEFORE consulting `repository` -- and
  # `terraform apply` runs from inside terraform/, which then contained terraform/jenkins/ (the
  # retired EC2 stack). `chart = "jenkins"` silently resolved to that directory instead of the Helm
  # repo. That directory was deleted on 2026-07-31, so the collision is gone and `version` is
  # load-bearing again: against a URL chart, Helm ignores `version` entirely, so bumping it alone
  # would have applied cleanly and installed nothing new.
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  version    = local.jenkins_chart_version
  namespace  = kubernetes_namespace.ci.metadata[0].name

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
        # Where application-cd sends its "this needs a human" notifications. A pod environment
        # variable, like the four above, for the same reason: a hardcoded topic ARN in a Jenkinsfile
        # would be a per-account value baked into a forkable repo, which the root CLAUDE.md calls a
        # bug. Empty is handled -- the notify step skips rather than failing a build over it.
        { name = "SNS_TOPIC", value = aws_sns_topic.notifications.arn },
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

      # Opt OUT of the CloudWatch observability addon's auto-instrumentation. That addon annotates
      # every pod in the cluster for all four runtimes and injects an agent per language; on this pod
      # it attached an OpenTelemetry JAVA agent to the JVM.
      #
      # It is pure cost here. Jenkins is a build controller, not a request/response service, so
      # Application Signals has no latency or error rate worth tracing -- and the agent cannot reach
      # its collector anyway: the collector is in-cluster on 10.0.0.0/16, which the NetworkPolicy in
      # charts/jenkins-support deliberately excludes so CI cannot reach RDS or the app.
      #
      # What it DID cost: ~10s of extra JVM startup on a controller designed to restart in seconds,
      # and a continuous stream of okhttp export stack traces that buried the real
      # ConfiguratorConflictException while debugging the first deploy.
      podAnnotations = {
        "instrumentation.opentelemetry.io/inject-java"   = "false"
        "instrumentation.opentelemetry.io/inject-python" = "false"
        "instrumentation.opentelemetry.io/inject-nodejs" = "false"
        "instrumentation.opentelemetry.io/inject-dotnet" = "false"
      }
    }

    # The CONTROLLER's service account. Deliberately carries NO role-arn annotation and therefore no
    # AWS permissions at all (design doc section 7: "Jenkins controller: none") -- it only needs the
    # namespace-scoped Role below, to create/watch/exec into agent pods.
    serviceAccount = {
      name = "jenkins"
    }

    # The AGENT service account, separate from the controller's. This is the one IRSA is bound to
    # (see data.aws_iam_policy_document.jenkins_trust above), so only agent pods -- which is to say
    # only builds -- can push to ECR. `create = true` because the chart does not create one by
    # default (serviceAccountAgent.create defaults to false).
    serviceAccountAgent = {
      create = true
      name   = "jenkins-agent"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.jenkins.arn
      }
    }

    # Namespace-scoped Role only, bound to the CONTROLLER's service account (chart default) -- it is
    # what lets the controller create/watch/delete/exec into agent pods, and has nothing to do with
    # AWS permissions. The chart's default is already namespaced; asserted by
    # scripts/tests/test-jenkins-chart.sh so a future chart bump cannot widen it unnoticed.
    rbac = { create = true, readSecrets = false }

    # JENKINS_HOME on EFS. See terraform/addon-efs.tf for why EFS and not EBS -- in one line: an EBS
    # volume is AZ-locked and this node group is 100% Spot, so an EBS PVC would eventually strand the
    # pod Pending in an AZ with no capacity. EFS has a mount target in every private subnet.
    #
    # The controller is still disposable by design. This preserves build history across a Spot
    # reclaim; it is not a dependency. JCasC rebuilds everything else from code.
    persistence = {
      enabled      = true
      storageClass = kubernetes_storage_class.efs.metadata[0].name
      size         = "8Gi"
      accessMode   = "ReadWriteOnce"
    }

    # No `agent = {...}` block: with JCasC.defaultConfig = false above, the chart never renders its
    # own Kubernetes cloud/podTemplate config, so `agent.enabled`/`agent.podName` etc. have no effect
    # -- the pod template that actually runs comes entirely from the `clouds:` block in
    # ci/jenkins/jenkins.yaml. An earlier version of this file set them anyway with a comment implying
    # they mattered; they did not.
  })]

  depends_on = [
    helm_release.jenkins_support,
    aws_acm_certificate_validation.jenkins,
    kubernetes_storage_class.efs,
  ]
}
