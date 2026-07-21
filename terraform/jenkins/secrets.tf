# Secret CONTAINER only -- same pattern as the main stack's terraform/secrets.tf. Terraform writes a
# placeholder and then ignores secret_string forever, so no real credential ever enters git or
# terraform.tfstate. A human seeds the real values once with scripts/seed-jenkins-secret.sh.
#
# Holds what JCasC cannot keep in a public repository:
#   JENKINS_ADMIN_USER      admin login
#   JENKINS_ADMIN_HASH      bcrypt hash of the admin password (JCasC accepts "#jbcrypt:..." directly,
#                           so the plaintext password never needs to exist anywhere)
#   GITHUB_DEPLOY_KEY       private half of the repo deploy key, used to push the tag-bump commit
#   GITHUB_WEBHOOK_SECRET   shared secret GitHub signs webhook deliveries with
#
# The deploy key is the reason this exists at all: before 2026-07-21 its only copy was inside
# Jenkins' own credential store on one EBS volume, encrypted with a key on that same volume. Losing
# the host meant losing a key that could not be recovered from anywhere -- it is not on the
# operator's laptop (~/.ssh/voteball-jenkins is the EC2 *login* key, a different key entirely).
resource "aws_secretsmanager_secret" "jenkins" {
  name        = "${var.cluster_name}/jenkins"
  description = "Jenkins admin + GitHub deploy key + webhook secret. Seeded manually; read at boot by JCasC."

  # NOT recovery_window_in_days = 0 (which the main stack uses). That stack is destroyed and rebuilt
  # routinely, where a same-named secret pending deletion blocks the next apply. This stack is never
  # destroyed, and the deploy key here is unrecoverable if lost, so keep the recovery window.
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "jenkins_placeholder" {
  secret_id     = aws_secretsmanager_secret.jenkins.id
  secret_string = jsonencode({ placeholder = "seed real values via scripts/seed-jenkins-secret.sh" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
