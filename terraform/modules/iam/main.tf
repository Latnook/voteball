# IRSA = IAM Roles for Service Accounts. Each role's trust policy federates the cluster's OIDC
# provider to ONE specific service account (sub) with audience sts.amazonaws.com. This is the
# concrete least-privilege story: two workloads touching the same bucket under DIFFERENT prefixes
# with DIFFERENT roles, and backend/frontend get no role at all.

# ---- worker: milestone alerts (SNS) + rollup snapshots (S3 snapshots/ only) ----
data "aws_iam_policy_document" "worker_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:devops-app:worker"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "worker_permissions" {
  statement {
    sid       = "PublishMilestones"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }
  statement {
    sid       = "WriteSnapshots"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.bucket_arn}/snapshots/*"] # write-only, snapshots/ prefix only
  }
}

resource "aws_iam_role" "worker" {
  name               = "${var.cluster_name}-worker-irsa"
  assume_role_policy = data.aws_iam_policy_document.worker_trust.json
}

resource "aws_iam_role_policy" "worker" {
  name   = "${var.cluster_name}-worker-permissions"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker_permissions.json
}

# ---- backup CronJob: nightly DB/results dump (S3 backups/ only) -- its OWN role, no SNS ----
data "aws_iam_policy_document" "backup_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:devops-app:backup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "backup_permissions" {
  statement {
    sid       = "WriteNightlyBackups"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.bucket_arn}/backups/*"] # write-only, backups/ prefix only, no SNS
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.cluster_name}-backup-irsa"
  assume_role_policy = data.aws_iam_policy_document.backup_trust.json
}

resource "aws_iam_role_policy" "backup" {
  name   = "${var.cluster_name}-backup-permissions"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.backup_permissions.json
}

# ---- Alertmanager: publish operational alerts to SNS (no S3, no anything else) ----
# Closes docs/production-readiness.md section 6: metrics were collected but Alertmanager routed
# nowhere, so a crashlooping pod or a stale worker was only ever noticed by a human looking.
#
# Alertmanager's native sns_configs signs requests with the AWS SDK's credential chain, so IRSA is
# all it needs -- no access keys, and no SMTP credentials on a cluster that would rather not hold
# them. Reuses the SNS topic the worker already publishes milestones to: one subscription to
# confirm, one place to look.
data "aws_iam_policy_document" "alertmanager_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      # The chart's SA name is <release>-alertmanager. Changing the release name in
      # addon-monitoring.tf without changing this string silently breaks alerting: the pod starts
      # fine and only fails when it first tries to publish.
      values = ["system:serviceaccount:observability:kube-prometheus-stack-alertmanager"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "alertmanager_permissions" {
  statement {
    sid       = "PublishAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }
}

resource "aws_iam_role" "alertmanager" {
  name               = "${var.cluster_name}-alertmanager-irsa"
  assume_role_policy = data.aws_iam_policy_document.alertmanager_trust.json
}

resource "aws_iam_role_policy" "alertmanager" {
  name   = "${var.cluster_name}-alertmanager-permissions"
  role   = aws_iam_role.alertmanager.id
  policy = data.aws_iam_policy_document.alertmanager_permissions.json
}

# ---- Grafana: read CloudWatch metrics and logs for dashboards ----
data "aws_iam_policy_document" "grafana_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      # The chart's SA name is <release>-grafana. Changing the release name in addon-monitoring.tf
      # without changing this string breaks the CloudWatch data source silently: Grafana starts
      # fine and only the panels fail, with an AccessDenied nobody is watching for.
      values = ["system:serviceaccount:observability:kube-prometheus-stack-grafana"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "grafana_permissions" {
  # Logs: resource-scoped to this cluster's three Fluent Bit log groups and nothing else.
  statement {
    sid    = "ReadClusterLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/containerinsights/${var.cluster_name}/*",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/containerinsights/${var.cluster_name}/*:log-stream:*",
    ]
  }

  # Metrics: CANNOT be resource-scoped. AWS publishes no IAM condition key for restricting
  # cloudwatch:GetMetricData or ListMetrics to a namespace, so these take Resource "*". The grant is
  # read-only and this is a single-purpose account; the asymmetry with the Logs statement above is
  # deliberate and is recorded in docs/security.md so it is not later read as an oversight.
  # See docs/design/2026-08-24-grafana-datasources-design.md decision 2.
  statement {
    sid    = "ReadMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${var.cluster_name}-grafana-irsa"
  assume_role_policy = data.aws_iam_policy_document.grafana_trust.json
}

resource "aws_iam_role_policy" "grafana" {
  name   = "${var.cluster_name}-grafana-permissions"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana_permissions.json
}

# ================== Jenkins CI/CD IRSA ==================
# Moved here from addon-jenkins.tf on 2026-09-07 so that ALL hand-rolled IRSA lives in one
# module. The community module.jenkins_cd_irsa deliberately stayed behind with the release it
# serves -- see docs/design/2026-09-07-terraform-module-layout-design.md sections 3a and 3b.

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
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:ci:jenkins-agent"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
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
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${var.cluster_name}-*"
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
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${var.cluster_name}-${r}"
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
    resources = [var.sns_topic_arn]
  }
}

resource "aws_iam_policy" "jenkins_cd_notify" {
  name   = "${var.cluster_name}-jenkins-cd-notify"
  policy = data.aws_iam_policy_document.jenkins_cd_notify.json
}

