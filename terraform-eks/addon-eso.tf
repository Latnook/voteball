# IRSA role for ESO, scoped read-only to the ONE app secret (not all of Secrets Manager). The helper's
# external_secrets policy grants secretsmanager:GetSecretValue/DescribeSecret on the given ARNs only.
module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                      = "${var.cluster_name}-eso-irsa"
  attach_external_secrets_policy = true
  # Scope to exactly the app secret (+ its 6-char random suffix) -- least privilege.
  external_secrets_secrets_manager_arns = ["${aws_secretsmanager_secret.app.arn}*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# External Secrets Operator (CNCF project): syncs the Secrets Manager voteball/app-secret into a
# Kubernetes Secret. Plan 3 wires the ExternalSecret/SecretStore that reference this SA's IRSA role.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.8.0" # verified latest via `helm search repo` on 2026-07-19 (app v2.8.0)
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eso_irsa.iam_role_arn
  }
}
