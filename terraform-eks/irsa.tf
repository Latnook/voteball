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
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:devops-app:worker"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "worker_permissions" {
  statement {
    sid       = "PublishMilestones"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
  }
  statement {
    sid       = "WriteSnapshots"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.rollups.arn}/snapshots/*"] # write-only, snapshots/ prefix only
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
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:devops-app:backup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "backup_permissions" {
  statement {
    sid       = "WriteNightlyBackups"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.rollups.arn}/backups/*"] # write-only, backups/ prefix only, no SNS
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
