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
}

resource "aws_secretsmanager_secret_version" "app_placeholder" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ placeholder = "seed real values via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
