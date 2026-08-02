#!/usr/bin/env bash
# Point GitHub at this cluster's Jenkins: register the deploy key and the push webhook.
#
# WHY THIS EXISTS: every destroy/rebuild mints a NEW deploy key and a NEW webhook secret, because
# terraform/secrets.tf recreates voteball/jenkins with recovery_window_in_days = 0 -- the old values are
# genuinely gone, and seed-jenkins-secret.sh generates replacements. GitHub still holds the previous
# pair. Until both are replaced the webhook is rejected (401, wrong HMAC) and the pipeline's final
# `git push` of the image-tag bump is denied (unauthorised key) -- and NOTHING in the deploy output
# warns you, because the deploy genuinely succeeded. Doing this by hand meant copying a public key and
# a one-time secret out of terminal scrollback on every rebuild, which is exactly the kind of step that
# gets skipped at 1am.
#
# IDEMPOTENT: compares the fingerprint of the key in Secrets Manager against the keys GitHub already
# holds. If GitHub already has this exact key AND a webhook for this URL, it changes nothing -- so
# deploy.sh can call it on every run, not just after a rebuild. Pass FORCE_REGISTER=1 to re-register
# regardless (e.g. after deleting the webhook by hand).
#
# Nothing secret is printed. The webhook secret and the private key are read from Secrets Manager
# straight into a private temp dir that is removed on exit; only the PUBLIC key's fingerprint is shown.
#
# Requires: aws CLI (logged in), jq, ssh-keygen, and gh authenticated with `repo` scope
# (`gh auth status`). Run it standalone at any time; deploy.sh also calls it as its last step.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh
require_config   # needs APP_DOMAIN for the webhook URL

SECRET_ID="${CLUSTER}/jenkins"
# owner/name comes from tfvars, never hardcoded -- a fork supplies its own (see variables.tf).
REPO="${GITHUB_REPO:-$(tfvar github_repo)}"
HOOK_URL="https://jenkins.${APP_DOMAIN}/github-webhook/"
KEY_TITLE="jenkins-ci"

if [ -z "$REPO" ]; then
  echo "ERROR: github_repo is not set in ${TFVARS} (and GITHUB_REPO is unset)." >&2
  echo "       It must be owner/name, e.g. your-org/your-repo." >&2
  exit 1
fi

for c in jq ssh-keygen gh; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' is required by $0." >&2; exit 1; }
done

# Fail closed, exactly like seed-jenkins-secret.sh's guard: an unauthenticated gh must stop here rather
# than fall through to the branch that DELETES the live deploy key and then cannot add a replacement.
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  echo "       Refusing to continue: this script deletes the old key before adding the new one," >&2
  echo "       so a half-authenticated run would leave GitHub with no usable deploy key at all." >&2
  exit 1
fi

TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

# ---- read the freshly-seeded credentials ---------------------------------------------------------
# From Secrets Manager, NOT from the deploy log. The log is a file on disk that outlives the run and
# would then contain the webhook secret in plaintext.
if ! aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
      --query SecretString --output text > "$TMP/secret.json" 2>"$TMP/err"; then
  echo "ERROR: could not read ${SECRET_ID}." >&2
  sed 's/^/       /' "$TMP/err" >&2
  echo "       Has ./scripts/seed-jenkins-secret.sh run yet? (deploy.sh step 3b)" >&2
  exit 1
fi

jq -re '.GITHUB_DEPLOY_KEY'     "$TMP/secret.json" > "$TMP/id_ed25519" || {
  echo "ERROR: ${SECRET_ID} holds no GITHUB_DEPLOY_KEY -- it is still the empty placeholder." >&2
  echo "       Run ./scripts/seed-jenkins-secret.sh first." >&2; exit 1; }
chmod 600 "$TMP/id_ed25519"
jq -re '.GITHUB_WEBHOOK_SECRET' "$TMP/secret.json" > "$TMP/webhook_secret"

# Derive the public half locally -- the private key never leaves this directory and is never sent.
ssh-keygen -y -f "$TMP/id_ed25519" > "$TMP/id_ed25519.pub"
VAULT_FP="$(ssh-keygen -lf "$TMP/id_ed25519.pub" | awk '{print $2}')"

echo "Repository : ${REPO}"
echo "Webhook    : ${HOOK_URL}"
echo "Deploy key : ${VAULT_FP}"

# ---- idempotency check ---------------------------------------------------------------------------
# GitHub never reveals a webhook secret, so it cannot be compared. The DEPLOY KEY can be, and the two
# are always rotated together by seed-jenkins-secret.sh -- so a matching key means the vault has not
# been reseeded since the last registration, and the webhook secret must still match too.
MATCHED_KEY=""
gh api "repos/${REPO}/keys" --jq '.[] | "\(.id)\t\(.key)"' > "$TMP/ghkeys" || true
while IFS=$'\t' read -r kid kbody; do
  [ -n "${kid:-}" ] || continue
  printf '%s\n' "$kbody" > "$TMP/ghkey.pub"
  fp="$(ssh-keygen -lf "$TMP/ghkey.pub" 2>/dev/null | awk '{print $2}')" || continue
  [ "$fp" = "$VAULT_FP" ] && MATCHED_KEY="$kid"
done < "$TMP/ghkeys"

HOOK_ID="$(gh api "repos/${REPO}/hooks" --jq ".[] | select(.config.url==\"${HOOK_URL}\") | .id" 2>/dev/null | head -1 || true)"

if [ "${FORCE_REGISTER:-0}" != "1" ] && [ -n "$MATCHED_KEY" ] && [ -n "$HOOK_ID" ]; then
  echo
  echo "Already registered (key ${MATCHED_KEY}, hook ${HOOK_ID}) -- nothing to do."
  echo "(Set FORCE_REGISTER=1 to re-register anyway.)"
  exit 0
fi

# ---- deploy key -----------------------------------------------------------------------------------
# Remove by TITLE as well as by fingerprint: a stale key from a previous rebuild has a different
# fingerprint but the same title, and GitHub allows duplicate titles -- so they would otherwise pile up
# one per rebuild, and it would stop being obvious which one Jenkins actually uses.
echo
echo "==> Deploy key"
gh api "repos/${REPO}/keys" --jq ".[] | select(.title==\"${KEY_TITLE}\") | .id" | while read -r id; do
  [ -n "$id" ] || continue
  gh api -X DELETE "repos/${REPO}/keys/${id}" --silent && echo "    removed stale key ${id}"
done

# read_only=false is REQUIRED, not a preference: the pipeline pushes its own
# "ci: image tag <sha> [skip ci]" commit back to master. A read-only key makes every build fail at the
# very last step, after the image has already been built, scanned and pushed.
gh api -X POST "repos/${REPO}/keys" \
  -f title="${KEY_TITLE}" \
  -f key="$(cat "$TMP/id_ed25519.pub")" \
  -F read_only=false \
  --jq '"    registered key \(.id) (write access: \(.read_only|not))"'

# ---- webhook ---------------------------------------------------------------------------------------
echo "==> Webhook"
gh api "repos/${REPO}/hooks" --jq ".[] | select(.config.url==\"${HOOK_URL}\") | .id" | while read -r id; do
  [ -n "$id" ] || continue
  gh api -X DELETE "repos/${REPO}/hooks/${id}" --silent && echo "    removed stale hook ${id}"
done

# Built with jq rather than -f flags so the secret is passed as a JSON value and never appears in this
# process's argv (where `ps` would show it to any other user on the machine).
jq -n --arg url "$HOOK_URL" --arg secret "$(cat "$TMP/webhook_secret")" \
  '{name:"web", active:true, events:["push"],
    config:{url:$url, content_type:"json", secret:$secret, insecure_ssl:"0"}}' > "$TMP/hook.json"
gh api -X POST "repos/${REPO}/hooks" --input "$TMP/hook.json" \
  --jq '"    registered hook \(.id)"'

# ---- prove it actually works ----------------------------------------------------------------------
# Registering a webhook and having one that DELIVERS are different things: a wrong secret, a
# not-yet-resolving DNS name or an ALB with no healthy targets all look identical from the API.
#
# GitHub fires its own ping the moment a hook is created, and immediately after a rebuild that ping
# reliably gets a 502 -- the ALB exists but its targets are still registering. Harmless, but it leaves
# a red delivery as the newest entry on the repo's webhook page, which reads as "CI is broken" to
# anyone who looks. So: retry until it succeeds, and leave a green delivery as the last word.
HOOK_ID="$(gh api "repos/${REPO}/hooks" --jq ".[] | select(.config.url==\"${HOOK_URL}\") | .id" | head -1)"
echo "==> Verifying delivery (a 502 here is the new ALB still warming up)"
ok=0
for attempt in 1 2 3 4 5 6; do
  gh api -X POST "repos/${REPO}/hooks/${HOOK_ID}/pings" --silent 2>/dev/null || true
  sleep 15
  code="$(gh api "repos/${REPO}/hooks/${HOOK_ID}/deliveries" --jq '[.[] | select(.event=="ping")][0].status_code' 2>/dev/null || echo "")"
  if [ "$code" = "200" ]; then
    echo "    delivered OK (attempt ${attempt})"
    ok=1
    break
  fi
  echo "    attempt ${attempt}: got '${code:-no response}', retrying"
done

echo
if [ "$ok" = "1" ]; then
  echo "GitHub now points at this cluster, and a test delivery succeeded."
else
  echo "WARNING: the webhook is registered but no ping has succeeded yet." >&2
  echo "         Usually just DNS/ALB warm-up — re-check in a few minutes:" >&2
  echo "           gh api repos/${REPO}/hooks/${HOOK_ID}/deliveries --jq '.[0]'" >&2
  echo "         If it stays failing, confirm https://jenkins.${APP_DOMAIN}/github-webhook/ resolves." >&2
fi
