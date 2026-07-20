# The build host authenticates to AWS via this role, attached to the instance itself -- no OIDC
# federation and no stored keys. Permissions are lifted verbatim from the retired
# terraform/github-oidc.tf: ECR push, and nothing else. No EKS, RDS, S3, SNS or Secrets Manager.
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

resource "aws_iam_role" "jenkins" {
  name               = "${var.cluster_name}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "jenkins_ecr" {
  name   = "${var.cluster_name}-jenkins-ecr"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_ecr.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.cluster_name}-jenkins"
  role = aws_iam_role.jenkins.name
}
