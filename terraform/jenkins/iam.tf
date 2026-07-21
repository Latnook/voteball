# The build host authenticates to AWS via this role, attached to the instance itself -- no OIDC
# federation and no stored keys. ECR push was lifted verbatim from the retired
# terraform/github-oidc.tf. No EKS, RDS, S3 or SNS -- this host still cannot reach the cluster or
# its data, and still never deploys; ArgoCD does.
#
# ONE addition since (2026-07-21): read access to a SINGLE Secrets Manager secret, so JCasC can
# configure the host's own credentials at boot instead of a human clicking them in. Deliberately
# GetSecretValue only, on one ARN -- not a wildcard, and no write. Note this grants no material the
# host did not already hold: the deploy key and webhook secret already live on its disk in Jenkins'
# credential store. What changes is that they now also exist somewhere the host's death does not
# take with it.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken is account-wide by design
  }
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    # Written as an ARN pattern rather than a reference to the main stack's repositories, so this
    # stack has no cross-stack dependency and applies cleanly while the cluster is destroyed.
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-*"
    ]
  }
}

data "aws_iam_policy_document" "jenkins_secrets" {
  statement {
    sid       = "ReadOwnSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.jenkins.arn]
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.cluster_name}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "jenkins_ecr" {
  name   = "${var.cluster_name}-jenkins-ecr"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_ecr.json
}

resource "aws_iam_role_policy" "jenkins_secrets" {
  name   = "${var.cluster_name}-jenkins-secrets"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_secrets.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.cluster_name}-jenkins"
  role = aws_iam_role.jenkins.name
}
