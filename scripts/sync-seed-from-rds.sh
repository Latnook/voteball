#!/usr/bin/env bash
# Usage: ./scripts/sync-seed-from-rds.sh [--apply]
#
# "Reverse seeding": diffs the live RDS instance's admin-editable data (leagues, clubs,
# previous_parties, upcoming_parties) against what the current working tree's schema.sql +
# seed.sql would produce, so admin-UI curation (e.g. logo URLs) that never made it into the repo
# can be caught and, for the safe subset, backfilled automatically.
#
# Default (no flags) is a dry-run report only. Pass --apply to have the safe NULL-backfill
# category written into seed.sql -- renames/deletions/additions are always report-only and need a
# human decision (see scripts/sync_seed_from_rds.py's module docstring for why).
#
# Requires: terraform state in terraform/ (for the RDS endpoint + EC2 IP), ansible-vault access to
# ansible-project/inventories/voteball/group_vars/all/secrets.yml (for db_pass), the EC2 SSH key
# (Voteball-EC2-pem.pem, per docs/deploy.md), and a local voteball-test-db container running (see
# CLAUDE.md's backend test setup) to hold the reseeded reference database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible-project"
BACKEND_DIR="$REPO_ROOT/ansible-project/roles/backend/files/backend"
SSH_KEY="$REPO_ROOT/Voteball-EC2-pem.pem"
TUNNEL_PORT=15432

APPLY_FLAG=()
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY_FLAG=(--apply) ;;
    --dump-rds-clubs) APPLY_FLAG=(--dump-rds-clubs) ;;
    --dump-rds-leagues) APPLY_FLAG=(--dump-rds-leagues) ;;
    *) echo "Unknown argument: $arg (only --apply / --dump-rds-clubs / --dump-rds-leagues are supported)" >&2; exit 1 ;;
  esac
done

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: EC2 SSH key not found at $SSH_KEY (see docs/deploy.md Setup step 1)." >&2
  exit 1
fi
if [ ! -f "$ANSIBLE_DIR/.vault_pass" ]; then
  echo "ERROR: $ANSIBLE_DIR/.vault_pass not found -- can't decrypt db_pass (see docs/deploy.md Setup step 3)." >&2
  exit 1
fi
if [ ! -d "$BACKEND_DIR/.venv" ]; then
  echo "ERROR: $BACKEND_DIR/.venv not found. Set up the backend's test venv first (see CLAUDE.md" >&2
  echo "        'Backend' common-commands section) -- this script reuses it for psycopg2." >&2
  exit 1
fi

cd "$TF_DIR"
APP_IP=$(terraform output -raw app_public_ip)
RDS_HOST=$(terraform output -raw rds_endpoint | cut -d: -f1)
cd "$REPO_ROOT"

DB_PASS=$(ansible-vault view "$ANSIBLE_DIR/inventories/voteball/group_vars/all/secrets.yml" \
  --vault-password-file "$ANSIBLE_DIR/.vault_pass" | grep '^db_pass:' | sed 's/^db_pass:[[:space:]]*//')
if [ -z "$DB_PASS" ]; then
  echo "ERROR: could not extract db_pass from secrets.yml." >&2
  exit 1
fi

echo "Opening SSH tunnel to RDS via $APP_IP (local port $TUNNEL_PORT)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
  -N -L "${TUNNEL_PORT}:${RDS_HOST}:5432" "ec2-user@${APP_IP}" &
TUNNEL_PID=$!

cleanup() {
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Give the tunnel a moment to establish; fail loudly rather than let the Python side hang on a
# connection that will never come up. Each check opens/closes its fd inside the subshell only,
# so nothing needs closing in the parent shell.
tunnel_up=false
for _ in 1 2 3 4 5 6 7 8; do
  if (exec 3<>"/dev/tcp/localhost/${TUNNEL_PORT}") 2>/dev/null; then
    tunnel_up=true
    break
  fi
  sleep 1
done
if [ "$tunnel_up" != true ]; then
  echo "ERROR: SSH tunnel did not come up on port $TUNNEL_PORT after 8s." >&2
  exit 1
fi

source "$BACKEND_DIR/.venv/bin/activate"
python3 "$SCRIPT_DIR/sync_seed_from_rds.py" \
  --port "$TUNNEL_PORT" \
  --password "$DB_PASS" \
  "${APPLY_FLAG[@]}"
