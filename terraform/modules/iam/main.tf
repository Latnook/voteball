locals {
  name_prefix = "voteball"
}

resource "aws_iam_policy" "app" {
  name = "${local.name_prefix}-app-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.notifications_topic_arn
      },
      # certbot's dns-route53 plugin (DNS-01 renewal) — same pattern as
      # S3App's iam module. ListHostedZones/GetChange have no resource-level
      # permissions in IAM and must stay "*"; only the actual record change
      # is zone-scoped.
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = var.hosted_zone_arn
      }
    ]
  })

  tags = {
    Voteball = "iam"
  }
}

resource "aws_iam_role" "app" {
  name        = "${local.name_prefix}-app-role"
  description = "Allows the Voteball EC2 instance to call AWS services on your behalf."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Voteball = "iam"
  }
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app.arn
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name_prefix}-app-role"
  role = aws_iam_role.app.name
}
