#!/usr/bin/env bash
# Copy the app's passwords from the encrypted Ansible vault into AWS Secrets Manager
# (voteball/app-secret) for the EKS deploy. No values are printed. Run from anywhere in the repo.
#
# Needs: aws login (account 590183895228), ansible-vault, ansible-project/.vault_pass, python3 + pyyaml.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

VAULT="ansible-project/inventories/voteball/group_vars/all/secrets.yml"
PASS="ansible-project/.vault_pass"

if [ ! -f "$PASS" ]; then
  echo "Missing $PASS (the vault password). Can't read the secrets file without it." >&2
  exit 1
fi

ansible-vault view "$VAULT" --vault-password-file "$PASS" | python3 -c '
import sys, json, subprocess, yaml
d = yaml.safe_load(sys.stdin)
secret = {
    "DB_USER": "postgres",
    "DB_PASS": d["db_pass"],
    "ADMIN_USERNAME": d["admin_username"],
    "ADMIN_PASSWORD_HASH": d["admin_password_hash"],
    "ADMIN_SESSION_SECRET": d["admin_session_secret"],
}
subprocess.run(
    ["aws", "secretsmanager", "put-secret-value",
     "--secret-id", "voteball/app-secret", "--region", "il-central-1",
     "--secret-string", json.dumps(secret)],
    check=True, stdout=subprocess.DEVNULL,
)
print("Done: copied 5 passwords into AWS Secrets Manager (voteball/app-secret). No values shown.")
'
