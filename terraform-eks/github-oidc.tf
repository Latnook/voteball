# Lets GitHub Actions assume a scoped role via OIDC -- no long-lived AWS keys. The trust is limited to
# this repo; the permissions are ECR push to the voteball-* repos only.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      # Scoped to the master branch only (the CI workflow's sole trigger) -- not a bare :* that would
      # let any branch/tag/PR in the repo assume this ECR-push role.
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:Latnook/voteball:ref:refs/heads/master"]
    }
  }
}

data "aws_iam_policy_document" "github_actions_ecr" {
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
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn] # voteball-backend/worker/nginx/backup only
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.cluster_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "${var.cluster_name}-github-actions-ecr"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
