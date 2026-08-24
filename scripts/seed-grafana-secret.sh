#!/usr/bin/env bash
# Seeds AWS Secrets Manager (<cluster_name>/grafana) with the two credentials the Grafana data
# sources need: the grafana_ro Postgres password and a fine-grained GitHub PAT.
#
# IDEMPOTENT, modeled on scripts/seed-jenkins-secret.sh's exit-early guard, NOT on
# scripts/seed-eks-secret.sh's every-run rewrite: re-running deploy.sh must never silently rotate
# db_password out from under a LIVE grafana_ro role. Once the secret holds a real password this
# script changes nothing unless FORCE_ROTATE=1 is set on purpose.
#
# Under FORCE_ROTATE=1 the new password does NOT reach the live role immediately. migrate.py's
# `ALTER ROLE grafana_ro PASSWORD ...` (services/backend/migrate.py) runs as a post-install,
# pre-upgrade Helm hook, so the change only takes effect on the NEXT release. Between rotating here
# and that release landing, the PostgreSQL data source keeps authenticating with the OLD password
# and starts failing the moment Secrets Manager holds the new one but the role does not yet.
#
# FORCE_ROTATE=1 alone rotates BOTH credentials. Pass ROTATE_WHAT=db_password or
# ROTATE_WHAT=github_token alongside it to rotate just one and carry the other forward unchanged --
# the two expire on unrelated schedules (github_token within a year, per GitHub; db_password never
# on its own), so the common case is rotating one without wanting to touch the other. See
# docs/maintenance.md's GitHub PAT rotation runbook, which is exactly this case.
#
# db_password is GENERATED here -- nothing human ever types it. github_token comes from the
# environment or a silent prompt on /dev/tty: a fine-grained PAT scoped to Latnook/voteball alone,
# read-only Contents + Metadata + Issues (see docs/design/2026-08-24-grafana-datasources-design.md
# decision 5 for why a fine-grained PAT was chosen over a classic one).
#
# Nothing is echoed and nothing is written to disk outside a private temp dir removed on exit.
#
# Requires: aws CLI (logged in), jq (idempotency check), openssl, python3.
set -euo pipefail

# The token variable is DELIBERATELY namespaced. `GITHUB_TOKEN` is a reserved name: git's credential
# helper and the `gh` CLI both consume it from the environment automatically. Putting it in deploy.env
# on 2026-08-24 meant every `git push` and every `gh` call in scripts/deploy.sh authenticated as a
# read-only, single-repo fine-grained PAT instead of the operator's own credentials -- step 9 failed
# with "Permission to Latnook/voteball.git denied", step 9's guard then refused to bootstrap ArgoCD,
# and the rebuild finished with no ArgoCD Applications and charts/observability never deployed.
# A bare GITHUB_TOKEN is still accepted here for muscle memory, but nothing EXPORTS it.
: "${GRAFANA_GITHUB_TOKEN:=${GITHUB_TOKEN:-}}"
cd "$(dirname "$0")/.."   # repo root

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh

SECRET_ID="${CLUSTER}/grafana"

# ---- idempotency guard ---------------------------------------------------------------------------
# Same fail-closed shape as seed-jenkins-secret.sh: three states, only two are safe to act on.
#   holds a real db_password -> skip, leave grafana_ro's live credential intact
#   absent / still the Terraform placeholder -> seed
#   CANNOT BE DETERMINED (jq missing, throttled, network blip) -> stop, and say why
# Guessing wrong here overwrites the password a live grafana_ro role is currently authenticating
# with -- the same class of mistake the Jenkins script's comment warns about, just for a database
# role instead of a GitHub deploy key.
if [ "${FORCE_ROTATE:-0}" != "1" ]; then
  command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required to check whether ${SECRET_ID} is already seeded." >&2
    echo "Refusing to continue: without it this script cannot tell an unseeded secret from an" >&2
    echo "unreadable one, and guessing wrong would rotate db_password out from under the live" >&2
    echo "grafana_ro role." >&2
    exit 1
  }

  set +e
  EXISTING="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
              --query SecretString --output text 2>&1)"
  aws_rc=$?
  set -e

  if [ "$aws_rc" -ne 0 ]; then
    # ResourceNotFoundException means the billed apply hasn't created the container yet -- a
    # legitimate "not ready", never treated as "seed away". Every other failure is unknown state.
    if printf '%s' "$EXISTING" | grep -q 'ResourceNotFoundException'; then
      echo "ERROR: ${SECRET_ID} does not exist yet." >&2
      echo "Run 'terraform apply -var-file=voteball.tfvars' first -- it creates the empty" >&2
      echo "container (with a placeholder value) that this script fills in." >&2
      exit 1
    else
      echo "ERROR: could not read ${SECRET_ID} to decide whether it is already seeded." >&2
      printf '%s\n' "$EXISTING" >&2
      echo "Refusing to continue: seeding now would overwrite a live db_password if one exists." >&2
      echo "Fix the access problem, or pass FORCE_ROTATE=1 if you genuinely intend to rotate." >&2
      exit 1
    fi
  elif printf '%s' "$EXISTING" | jq -e '(.db_password // "") | length > 0' >/dev/null 2>&1; then
    echo "${SECRET_ID} already holds a real db_password -- leaving it, and the live grafana_ro role, intact."
    echo "(Set FORCE_ROTATE=1 to rotate deliberately. The new password reaches grafana_ro only on the"
    echo " NEXT release -- migrate.py's ALTER ROLE runs as a post-install,pre-upgrade Helm hook, not"
    echo " immediately -- so the PostgreSQL data source will fail to authenticate until that release syncs.)"
    exit 0
  fi
fi

# ---- ROTATE_WHAT: rotate one credential without touching the other -----------------------------
# Default 'both' preserves the original behaviour (a full re-seed / first seed generates and writes
# both values). The two credentials rotate on completely different schedules and for different
# reasons -- db_password never expires on its own, github_token does (GitHub caps a fine-grained PAT
# at one year) -- so the common real-world rotation is "the PAT expired, mint a new one", which has
# nothing to do with db_password. Before ROTATE_WHAT existed, that runbook was
# `GRAFANA_GITHUB_TOKEN=<new> FORCE_ROTATE=1 ./scripts/seed-grafana-secret.sh`, which *always* regenerated
# db_password too -- since the new password only reaches the live grafana_ro role on the NEXT
# release (migrate.py's ALTER ROLE hook), that silently broke Business Analytics for an unbounded
# window every time someone rotated an expiring PAT. docs/maintenance.md's runbook now passes
# ROTATE_WHAT=github_token specifically to avoid this.
ROTATE_WHAT="${ROTATE_WHAT:-both}"
case "$ROTATE_WHAT" in
  both|db_password|github_token) ;;
  *)
    echo "ERROR: ROTATE_WHAT must be 'both', 'db_password' or 'github_token' (got '${ROTATE_WHAT}')." >&2
    exit 1
    ;;
esac

# ---- validate ROTATE_WHAT + FORCE_ROTATE combination -------------------------------------------------
# ROTATE_WHAT != "both" (i.e., rotating just one credential) requires FORCE_ROTATE=1. Without it, the
# code that fetches the EXISTING value of whichever credential is NOT being rotated never runs
# (lines 107-133 check FORCE_ROTATE=1), so both EXISTING_DB_PASSWORD and EXISTING_GITHUB_TOKEN stay
# empty. The assignment at line 163 or 173 then writes an empty value to Secrets Manager: a silent
# data loss that looks like success. Reject this unsupported combination loudly before any AWS call.
if [ "$ROTATE_WHAT" != "both" ] && [ "${FORCE_ROTATE:-0}" != "1" ]; then
  echo "ERROR: ROTATE_WHAT=${ROTATE_WHAT} requires FORCE_ROTATE=1." >&2
  echo "Without FORCE_ROTATE=1, this script cannot safely rotate just one credential — the other" >&2
  echo "value would be silently lost (written as empty to Secrets Manager)." >&2
  echo "Run with: ROTATE_WHAT=${ROTATE_WHAT} FORCE_ROTATE=1 ./scripts/seed-grafana-secret.sh" >&2
  exit 1
fi

EXISTING_DB_PASSWORD=""
EXISTING_GITHUB_TOKEN=""
if [ "${FORCE_ROTATE:-0}" = "1" ] && [ "$ROTATE_WHAT" != "both" ]; then
  # A partial rotation needs the CURRENT value of whichever credential is NOT being rotated, so it
  # can be carried forward unchanged instead of silently regenerated/dropped.
  set +e
  EXISTING="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
              --query SecretString --output text 2>&1)"
  aws_rc=$?
  set -e
  if [ "$aws_rc" -ne 0 ]; then
    echo "ERROR: ROTATE_WHAT=${ROTATE_WHAT} needs to read the CURRENT ${SECRET_ID} to carry forward" >&2
    echo "the value that isn't being rotated, and that read failed:" >&2
    printf '%s\n' "$EXISTING" >&2
    exit 1
  fi
  EXISTING_DB_PASSWORD="$(printf '%s' "$EXISTING" | jq -r '.db_password // empty')"
  EXISTING_GITHUB_TOKEN="$(printf '%s' "$EXISTING" | jq -r '.github_token // empty')"
  if [ "$ROTATE_WHAT" = "github_token" ] && [ -z "$EXISTING_DB_PASSWORD" ]; then
    echo "ERROR: ${SECRET_ID} has no existing db_password to carry forward -- run with" >&2
    echo "ROTATE_WHAT=both (or unset) to seed both values the first time." >&2
    exit 1
  fi
  if [ "$ROTATE_WHAT" = "db_password" ] && [ -z "$EXISTING_GITHUB_TOKEN" ]; then
    echo "ERROR: ${SECRET_ID} has no existing github_token to carry forward -- run with" >&2
    echo "ROTATE_WHAT=both (or unset) to seed both values the first time." >&2
    exit 1
  fi
fi

if [ "${FORCE_ROTATE:-0}" = "1" ] && [ "$ROTATE_WHAT" != "github_token" ]; then
  echo "FORCE_ROTATE=1 (rotating db_password): the NEW password reaches the live grafana_ro role"
  echo "only on the NEXT release -- migrate.py's ALTER ROLE grafana_ro runs as a"
  echo "post-install,pre-upgrade Helm hook, not immediately. Until that release syncs, the"
  echo "PostgreSQL data source keeps using the OLD password and will start failing to authenticate"
  echo "as soon as Secrets Manager holds this new one."
  echo
fi

echo "Seeding ${SECRET_ID} in ${REGION}."
echo

# Prompt only when unset/empty; -s so nothing appears on screen. Same idiom as seed-eks-secret.sh's
# ask(), reading from /dev/tty explicitly so this still works when stdin is otherwise occupied (e.g.
# deploy.sh's own prompts earlier in the same run). MANDATORY -- used only for an explicit
# ROTATE_WHAT=github_token FORCE_ROTATE=1 rotation, where a human deliberately asked to change this
# one value and an empty answer would silently drop it.
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

# Test the terminal by actually opening /dev/tty, not `[ -r /dev/tty ]` -- same guard deploy.sh uses
# for the same reason (a permissions check returns true in exactly the detached case this exists to
# catch).
has_tty() { (exec </dev/tty) 2>/dev/null; }

if [ "$ROTATE_WHAT" = "github_token" ]; then
  DB_PASSWORD="$EXISTING_DB_PASSWORD"
  echo "ROTATE_WHAT=github_token: leaving db_password exactly as it is -- grafana_ro's live"
  echo "password is untouched, so nothing about the PostgreSQL data source changes."
  echo
else
  # db_password: GENERATED, never prompted for -- nothing human types this value.
  DB_PASSWORD="$(openssl rand -hex 24)"
fi

if [ "$ROTATE_WHAT" = "db_password" ]; then
  GRAFANA_GITHUB_TOKEN="$EXISTING_GITHUB_TOKEN"
  echo "ROTATE_WHAT=db_password: leaving github_token exactly as it is."
  echo
elif [ "$ROTATE_WHAT" = "github_token" ]; then
  # An explicit, deliberate rotation of just this value (docs/maintenance.md's PAT-expiry runbook) --
  # an empty answer here would silently drop the token, so this path stays mandatory.
  GRAFANA_GITHUB_TOKEN="$(ask GRAFANA_GITHUB_TOKEN "GitHub fine-grained PAT for Latnook/voteball (not echoed)")"
else
  # ROTATE_WHAT=both, the path deploy.sh's automated seeding step actually takes on a fresh cluster.
  # GRAFANA_GITHUB_TOKEN is OPTIONAL here, unlike db_password (always generated) and unlike the admin/Jenkins
  # credentials deploy.sh's own preflight requires: an unattended deploy must not hang on a prompt
  # nobody can answer, and it must not fail over a token that guards nothing load-bearing --
  # docs/design/2026-08-24-grafana-datasources-design.md decision 5 is explicit that no alert, SLI or
  # incident path depends on the GitHub data source. So: use it if already supplied (deploy.env, CI,
  # an explicit override); prompt for it, optionally, only if a human is actually at a terminal;
  # otherwise skip silently. The payload below omits the key entirely rather than writing an empty
  # string -- see the split ExternalSecret this feeds (charts/observability/templates/
  # externalsecret.yaml), which now gates the GitHub token independently of db_password for exactly
  # this reason.
  if [ -n "${GRAFANA_GITHUB_TOKEN:-}" ]; then
    : # already supplied
  elif has_tty; then
    read -rsp "GitHub fine-grained PAT for Latnook/voteball (optional -- Enter to skip): " GRAFANA_GITHUB_TOKEN </dev/tty
    echo >&2
  else
    GRAFANA_GITHUB_TOKEN=""
  fi
  if [ -z "$GRAFANA_GITHUB_TOKEN" ]; then
    # Nothing new was supplied. `put-secret-value` REPLACES the whole SecretString, so simply
    # omitting the key here would DELETE an already-stored token, not merely "not add" one -- this
    # matters on the FORCE_ROTATE=1-alone path (rotating db_password without ROTATE_WHAT=db_password),
    # which reaches this branch too. Best-effort carry-forward of whatever is already there; only a
    # secret that never had a token (the true first-seed case deploy.sh's automated step actually
    # hits) ends up with none.
    set +e
    GRAFANA_GITHUB_TOKEN="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
                     --query SecretString --output text 2>/dev/null | jq -r '.github_token // empty' 2>/dev/null)"
    set -e
    if [ -n "$GRAFANA_GITHUB_TOKEN" ]; then
      echo "No new GitHub token supplied -- keeping the one already stored in ${SECRET_ID} unchanged."
    else
      echo "No GitHub token supplied -- seeding db_password only. The GitHub data source provisions with"
      echo "no credential (not an empty one) and its panels stay blank; nothing else is affected. Add it"
      echo "later with:"
      echo "  GRAFANA_GITHUB_TOKEN=... ROTATE_WHAT=github_token FORCE_ROTATE=1 ./scripts/seed-grafana-secret.sh"
    fi
    echo
  fi
fi

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# github_token is included only when non-empty -- writing it as "" would be indistinguishable from a
# typo'd key to ESO/Grafana (both silently accept an empty string; see the design doc's silent-
# failure #2), so its ABSENCE is the only way to represent "not provided" without that ambiguity.
DB_PASSWORD="$DB_PASSWORD" GRAFANA_GITHUB_TOKEN="$GRAFANA_GITHUB_TOKEN" python3 -c '
import json, os
payload = {"db_password": os.environ["DB_PASSWORD"]}
if os.environ.get("GRAFANA_GITHUB_TOKEN"):
    payload.update({"github_token": os.environ["GRAFANA_GITHUB_TOKEN"]})
print(json.dumps(payload))' > "$TMP/payload.json"

# Capture the exit status separately from the output and branch on it explicitly -- never fold a
# command's exit status into a message that also asserts success. A discarded status here is exactly
# the shape that would print "Stored" over a failed put-secret-value.
set +e
RESULT="$(aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --secret-string "file://$TMP/payload.json" \
  --query '[Name,VersionId]' --output text 2>&1)"
put_rc=$?
set -e

if [ "$put_rc" -ne 0 ]; then
  echo "ERROR: put-secret-value failed; ${SECRET_ID} was NOT updated." >&2
  printf '%s\n' "$RESULT" >&2
  exit 1
fi

echo "Stored. ${RESULT}"
echo
echo "Nothing was printed or written to disk."
echo
echo "charts/voteball's externalSecret.grafanaEnabled and charts/observability's externalSecret.enabled"
echo "are already committed true, so no chart flag needs flipping. What still has to happen, both"
echo "documented in docs/deploy.md:"
echo
echo "  1. ArgoCD has to sync the ExternalSecrets that read this value (automatic once the release"
echo "     branch names a commit after this secret existed) -- the migrate Job's post-install,"
echo "     pre-upgrade hook then sets grafana_ro's live password from it on that same sync."
echo "  2. Grafana has to be RESTARTED to pick the projected credential up -- envFromSecret(s) only"
echo "     projects a Secret's keys at pod start, never again. deploy.sh's step 11d does this"
echo "     automatically and only when needed; run it by hand otherwise:"
echo "       ./scripts/restart-grafana-datasources.sh"
