# IRSA for the CloudWatch agent. No pre-baked helper toggle exists for CloudWatch, so attach AWS's
# managed CloudWatchAgentServerPolicy (write-only telemetry: logs:PutLogEvents/CreateLogStream/
# CreateLogGroup + cloudwatch:PutMetricData) via role_policy_arns. The add-on's SA is
# amazon-cloudwatch:cloudwatch-agent.
module "cloudwatch_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-cloudwatch-irsa"
  role_policy_arns = {
    cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
    }
  }
}

# CloudWatch Container Insights (AWS-managed EKS add-on): deploys the CloudWatch agent + Fluent Bit
# for pod logs + performance metrics to CloudWatch. Logging lives outside the cluster (AWS-native,
# IAM-gated) -- keeps the node RAM budget lighter than an in-cluster Loki.
resource "aws_eks_addon" "cloudwatch" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  addon_version            = "v6.3.0-eksbuild.1" # verified for K8s 1.34 via aws eks describe-addon-versions (2026-07-19)
  service_account_role_arn = module.cloudwatch_irsa.iam_role_arn
}
