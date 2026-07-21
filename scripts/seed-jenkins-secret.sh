#!/usr/bin/env bash
# Seeds AWS Secrets Manager (<cluster_name>/jenkins) with everything JCasC needs to configure the
# build host: the admin login, the GitHub deploy key, and the webhook shared secret.
#
# Run this ONCE per account, before the Jenkins host first boots. Terraform creates only the empty
# container (terraform/jenkins/secrets.tf), so no credential ever enters git or tfstate.
#
# Nothing is echoed and nothing is written to disk outside a private temp dir that is removed on
# exit. The generated deploy key's PUBLIC half is printed -- that is the one value you must copy,
# into GitHub -> repo Settings -> Deploy keys, WITH "Allow write access" ticked (the pipeline pushes
# the image-tag bump commit back to master).
#
# Same shape as scripts/seed-eks-secret.sh, which does this for the application stack.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh

SECRET_ID="${CLUSTER}/jenkins"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "Seeding ${SECRET_ID} in ${REGION}."
echo

# ---- admin login --------------------------------------------------------------------------------
ADMIN_USER="${JENKINS_ADMIN_USER:-}"
if [ -z "$ADMIN_USER" ]; then
  read -r -p "Jenkins admin username: " ADMIN_USER
fi

ADMIN_PASS="${JENKINS_ADMIN_PASSWORD:-}"
if [ -z "$ADMIN_PASS" ]; then
  read -r -s -p "Jenkins admin password (not echoed): " ADMIN_PASS; echo
fi
[ -n "$ADMIN_PASS" ] || { echo "ERROR: password must not be empty" >&2; exit 1; }

# JCasC accepts a bcrypt hash directly ("#jbcrypt:$2a$..."), so the PLAINTEXT password is never
# stored -- not in Secrets Manager, not in git, not on this machine. Python's bcrypt is used if
# present; otherwise htpasswd from httpd-tools. Jenkins requires the $2a$ prefix specifically.
if python3 -c "import bcrypt" 2>/dev/null; then
  ADMIN_HASH="#jbcrypt:$(ADMIN_PASS="$ADMIN_PASS" python3 -c '
import bcrypt, os
print(bcrypt.hashpw(os.environ["ADMIN_PASS"].encode(), bcrypt.gensalt(rounds=10, prefix=b"2a")).decode())
')"
elif command -v htpasswd >/dev/null 2>&1; then
  ADMIN_HASH="#jbcrypt:$(htpasswd -nbBC 10 "" "$ADMIN_PASS" | tr -d ':\n' | sed 's/^\$2y\$/$2a$/')"
else
  echo "ERROR: need either python3 with bcrypt (pip install bcrypt) or htpasswd (httpd-tools)." >&2
  exit 1
fi
unset ADMIN_PASS

# ---- deploy key ---------------------------------------------------------------------------------
# Generated here rather than reused: a deploy key should be unique to the host that holds it, and
# generating it means the private half exists in Secrets Manager from the very first moment rather
# than only inside Jenkins (which is the failure this whole design exists to prevent).
ssh-keygen -t ed25519 -N "" -C "jenkins-deploy" -f "$TMP/deploy_key" >/dev/null

# ---- webhook secret -----------------------------------------------------------------------------
WEBHOOK_SECRET="$(openssl rand -hex 32)"

# ---- assemble and store -------------------------------------------------------------------------
# Built with python rather than string concatenation: the private key is multi-line and must be JSON
# escaped exactly, INCLUDING its trailing newline. A key that loses that newline cannot be loaded by
# OpenSSH at all, and fails later as a misleading "Permission denied (publickey)".
KEY_PATH="$TMP/deploy_key" ADMIN_USER="$ADMIN_USER" ADMIN_HASH="$ADMIN_HASH" \
WEBHOOK_SECRET="$WEBHOOK_SECRET" python3 -c '
import json, os
with open(os.environ["KEY_PATH"], encoding="utf-8") as fh:
    key = fh.read()
assert key.endswith("\n"), "generated key lost its trailing newline"
print(json.dumps({
    "JENKINS_ADMIN_USER":    os.environ["ADMIN_USER"],
    "JENKINS_ADMIN_HASH":    os.environ["ADMIN_HASH"],
    "GITHUB_DEPLOY_USER":    "git",
    "GITHUB_DEPLOY_KEY":     key,
    "GITHUB_WEBHOOK_SECRET": os.environ["WEBHOOK_SECRET"],
}))' > "$TMP/payload.json"

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --secret-string "file://$TMP/payload.json" \
  --query '[Name,VersionId]' --output text

echo
echo "Stored. Two manual steps remain -- both need values only you can place:"
echo
echo "1. Add this PUBLIC key to GitHub -> Settings -> Deploy keys, WITH write access:"
echo
cat "$TMP/deploy_key.pub"
echo
echo "2. Add the webhook (repo -> Settings -> Webhooks):"
echo "     Payload URL:  http://<elastic-ip>:8080/github-webhook/"
echo "     Content type: application/json"
echo "     Secret:       printed once below -- copy it now, it is not stored anywhere else readable"
echo
echo "     $WEBHOOK_SECRET"
echo
echo "The Jenkins admin password is NOT recoverable from Secrets Manager (only its bcrypt hash is"
echo "stored). Re-run this script to set a new one."
