# Secret CONTAINER only. Terraform seeds a placeholder, then ignores secret_string forever, so the
# real DB/admin credentials NEVER land in terraform.tfstate. A human seeds them once:
#   aws secretsmanager put-secret-value --secret-id voteball/app-secret --region il-central-1 \
#     --secret-string '{"DB_USER":"postgres","DB_PASS":"...","ADMIN_USERNAME":"...",
#                       "ADMIN_PASSWORD_HASH":"...","ADMIN_SESSION_SECRET":"..."}'
# DB_PASS must match the RDS master password. External Secrets Operator (Plan 2b) syncs this into a
# K8s Secret via IRSA. Rotate these values on migration (the old vault ciphertext is in public git).
resource "aws_secretsmanager_secret" "app" {
  name        = "${var.cluster_name}/app-secret"
  description = "Voteball app credentials (DB + admin). Seeded manually; synced to K8s by ESO."

  # No secret value here is ever real data outside this cluster's lifetime (it's re-seeded from the
  # vault file via seed-eks-secret.sh after every apply). Force-delete on destroy instead of the
  # default 30-day recovery window, which otherwise blocks recreating a same-named secret after a
  # destroy/rebuild cycle (hit on 2026-07-20: "already scheduled for deletion").
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_placeholder" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ placeholder = "seed real values via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---- Jenkins CI secret ----
# Moved out of the retired terraform/jenkins/ stack on 2026-07-30 by `terraform state rm` there and
# `terraform import` here, so the live secret was never destroyed and recreated. Recreating it was
# not an option: Secrets Manager names are unique and a deleted secret blocks its own name for the
# whole recovery window, and the GITHUB_DEPLOY_KEY inside cannot be recovered from anywhere else.
#
# recovery_window_in_days = 0, UNLIKE the 7 the old stack used. That stack was never destroyed; this
# one is destroyed and rebuilt routinely, and a same-named secret pending deletion for 7 days blocks
# the next apply outright. The cost of 0 is real and is handled by process, not by Terraform:
# scripts/deploy.sh re-seeds this secret on every rebuild, and the operator must hold a copy of the
# deploy key outside AWS. See docs/cicd.md.
resource "aws_secretsmanager_secret" "jenkins" {
  name                    = "${var.cluster_name}/jenkins"
  description             = "Jenkins admin + GitHub deploy key + webhook secret. Seeded by scripts/seed-jenkins-secret.sh; read at boot by JCasC via ESO."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jenkins_placeholder" {
  secret_id     = aws_secretsmanager_secret.jenkins.id
  secret_string = jsonencode({ placeholder = "seed real values via scripts/seed-jenkins-secret.sh" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---- Grafana data source credentials ----
# Two values, one container: the grafana_ro Postgres password and a fine-grained GitHub PAT.
# Projected by TWO ExternalSecrets (charts/observability and charts/voteball) rather than one, so
# the GitHub token never enters the application namespace -- the migrate Job needs the DB password
# and has no business holding a repo credential.
#
# recovery_window_in_days = 0 for the same reason as the two above: this stack is destroyed and
# rebuilt routinely, and a same-named secret pending deletion blocks the next apply outright.
resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.cluster_name}/grafana"
  description             = "Grafana data source credentials (grafana_ro DB password + GitHub PAT). Seeded by scripts/seed-grafana-secret.sh; synced to K8s by ESO."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_placeholder" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({ placeholder = "seed real values via scripts/seed-grafana-secret.sh" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
