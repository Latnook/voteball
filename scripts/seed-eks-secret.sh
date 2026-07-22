#!/usr/bin/env bash
# Seed the app's credentials into AWS Secrets Manager (<cluster>/app-secret), where External Secrets
# Operator picks them up and syncs them into the app-secret Kubernetes Secret.
#
# Values come from the environment, or are prompted for. Nothing is echoed, and nothing is written to
# disk -- the plaintext admin password never leaves this process (only its hash is stored).
#
#   DB_PASS         must match db_password in your terraform/voteball.tfvars
#   ADMIN_USERNAME  admin login for admin.html            (default: admin)
#   ADMIN_PASSWORD  admin password; hashed here with werkzeug
#   DB_USER         database user                          (default: postgres)
#
# ADMIN_SESSION_SECRET is generated fresh each run. Re-running this script therefore invalidates every
# outstanding admin session token -- which is also how you revoke them.
#
# Requires: aws CLI (logged in), python3 with werkzeug, openssl.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh

# Prompt only when the variable is unset/empty; -s so nothing appears on screen.
ask() {
  local var="$1" prompt="$2" val="${!1:-}"
  if [ -z "$val" ]; then
    read -rsp "$prompt: " val </dev/tty && echo >&2
  fi
  if [ -z "$val" ]; then
    echo "ERROR: $var must not be empty." >&2
    exit 1
  fi
  printf '%s' "$val"
}

# db_password already lives in voteball.tfvars, and Terraform sets RDS's password from it -- so read
# it from there by default rather than asking, which guarantees the seeded DB_PASS matches RDS. Only
# falls through to a prompt if the key is absent (or DB_PASS was passed in the environment).
if [ -z "${DB_PASS:-}" ] && DB_PASS="$(tf_db_password)" && [ -n "$DB_PASS" ]; then
  echo "Using db_password from ${TFVARS}." >&2
fi
DB_PASS="$(ask DB_PASS "Database password (db_password from your tfvars)")"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="$(ask ADMIN_PASSWORD "Admin password for '${ADMIN_USERNAME}'")"

SECRET_ID="${CLUSTER}/app-secret"

# werkzeug hashes the admin password, but it is a backend dependency -- it is often NOT installed
# system-wide (it isn't on the maintainer's machine). Fall back to the backend's virtualenv, which
# has it from requirements.txt, before giving up. Override with PYTHON=/path/to/python.
pick_python() {
  local c
  for c in "${PYTHON:-}" python3 python "services/backend/.venv/bin/python"; do
    [ -n "$c" ] || continue
    if "$c" -c 'import werkzeug' >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

if ! PY="$(pick_python)"; then
  echo "ERROR: no Python with werkzeug available." >&2
  echo "  Install it:            pip install werkzeug" >&2
  echo "  Or create the backend venv:" >&2
  echo "      python -m venv services/backend/.venv" >&2
  echo "      services/backend/.venv/bin/pip install -r services/backend/requirements.txt" >&2
  echo "  Or point at your own:  PYTHON=/path/to/python ./scripts/seed-eks-secret.sh" >&2
  exit 1
fi

DB_USER="${DB_USER:-postgres}" DB_PASS="$DB_PASS" \
ADMIN_USERNAME="$ADMIN_USERNAME" ADMIN_PASSWORD="$ADMIN_PASSWORD" \
ADMIN_SESSION_SECRET="$(openssl rand -hex 32)" \
SECRET_ID="$SECRET_ID" AWS_REGION_ARG="$REGION" \
"$PY" - <<'PY'
import json, os, subprocess, sys

try:
    from werkzeug.security import generate_password_hash
except ImportError:
    sys.exit("ERROR: werkzeug not installed. Try: pip install werkzeug\n"
             "       (or activate services/backend/.venv, which already has it)")

secret = {
    "DB_USER": os.environ["DB_USER"],
    "DB_PASS": os.environ["DB_PASS"],
    "ADMIN_USERNAME": os.environ["ADMIN_USERNAME"],
    "ADMIN_PASSWORD_HASH": generate_password_hash(os.environ["ADMIN_PASSWORD"]),
    "ADMIN_SESSION_SECRET": os.environ["ADMIN_SESSION_SECRET"],
}

subprocess.run(
    ["aws", "secretsmanager", "put-secret-value",
     "--secret-id", os.environ["SECRET_ID"],
     "--region", os.environ["AWS_REGION_ARG"],
     "--secret-string", json.dumps(secret)],
    check=True, stdout=subprocess.DEVNULL,
)
print(f"Done: seeded 5 values into {os.environ['SECRET_ID']}. "
      "Nothing was printed or written to disk.")
PY
