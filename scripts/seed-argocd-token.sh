#!/usr/bin/env bash
# Mints (or verifies) an ArgoCD API token for the `jenkins-cd` local account and merges it into
# voteball/jenkins, WITHOUT disturbing the other five keys already there.
#
# WHY THIS EXISTS: `application-cd` authenticates to ArgoCD with ARGOCD_AUTH_TOKEN, read from
# voteball/jenkins. Nothing else ever generates that value -- seed-jenkins-secret.sh only ever
# copies it from the environment (empty by default, since ArgoCD does not exist on a fresh install
# until Terraform creates it), and it EXITS EARLY once a deploy key is present, so a re-seed can
# never fill it in either. Left alone, a destroy -> rebuild leaves the secret with an EMPTY token,
# JCasC logs "Found unresolved variable 'ARGOCD_AUTH_TOKEN'. Will default to empty string" and boots
# anyway, deploy.sh reports complete success, and every application-cd build then fails at Deploy
# with an ArgoCD auth error -- the same class of trap seed-jenkins-secret.sh/register-github-ci.sh
# already solved for the GitHub deploy key and webhook secret. This is that fix for the ArgoCD side.
#
# IDEMPOTENT in the useful sense: by default, if voteball/jenkins already holds a non-empty
# ARGOCD_AUTH_TOKEN that still authenticates as jenkins-cd, this changes nothing and says so.
# FORCE_ROTATE=1 mints a new one regardless (e.g. after a leaked token). Same flag name and shape as
# seed-jenkins-secret.sh's guard.
#
# Talks to the ArgoCD API directly (no `argocd` CLI dependency): port-forwards argocd-server,
# reads the admin password from argocd-initial-admin-secret, POSTs /api/v1/session, then POSTs
# /api/v1/account/jenkins-cd/token. The port-forward is always killed on exit, success or failure.
#
# NEVER echoes the token or the admin password -- only lengths, or "ok"/"valid".
#
# Fails closed if the jenkins-cd account does not exist yet: it is created by `terraform apply` of
# the ArgoCD release (terraform/addon-argocd.tf's accounts.jenkins-cd = apiKey), so this must run
# after that apply, not before.
#
# After writing the secret, forces an External Secrets Operator refresh AND restarts the Jenkins
# controller. Both are required, not just the first: `containerEnvFrom` projects the secret into the
# pod's environment at container START, so an already-running controller never sees a token added
# after it booted -- confirmed live on 2026-08-04 (token correct in Secrets Manager *and* in the
# synced Kubernetes Secret, JCasC still resolving it empty).
#
# Requires: aws CLI (logged in), kubectl (pointed at the cluster), jq, curl, python3 is NOT needed.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh
require_config

SECRET_ID="${CLUSTER}/jenkins"
ARGOCD_NAMESPACE="argocd"
ARGOCD_LOCAL_PORT="${ARGOCD_LOCAL_PORT:-8081}"
ACCOUNT="jenkins-cd"

for c in aws jq kubectl curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' is required by $0." >&2; exit 1; }
done

TMP="$(mktemp -d)"
chmod 700 "$TMP"
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- read the existing secret, fail closed on anything but "not seeded yet" ----------------------
# Same reasoning as seed-jenkins-secret.sh's guard: an unreadable secret must never be treated as an
# empty one, or a transient AWS error could look identical to "needs seeding" and this script would
# barrel ahead and mint (and then discard) a token unnecessarily, or worse, write a payload built
# from a truncated read.
if ! aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
      --query SecretString --output text > "$TMP/secret.json" 2>"$TMP/err"; then
  echo "ERROR: could not read ${SECRET_ID}." >&2
  sed 's/^/       /' "$TMP/err" >&2
  echo "       Has ./scripts/seed-jenkins-secret.sh run yet (deploy.sh step 3b)?" >&2
  exit 1
fi

EXISTING_TOKEN="$(jq -r '.ARGOCD_AUTH_TOKEN // ""' "$TMP/secret.json")"

# ---- helpers --------------------------------------------------------------------------------------
BASE_URL="https://localhost:${ARGOCD_LOCAL_PORT}"

start_port_forward() {
  [ -n "$PF_PID" ] && return 0   # already running
  kubectl -n "$ARGOCD_NAMESPACE" port-forward svc/argocd-server "${ARGOCD_LOCAL_PORT}:443" \
      >"$TMP/pf.log" 2>&1 &
  PF_PID=$!
  # Poll readiness instead of a fixed sleep -- and detect a port-forward that died immediately
  # (e.g. the local port is already in use) rather than spinning until the timeout.
  local i
  for i in $(seq 1 30); do
    if curl -sk -o /dev/null "${BASE_URL}/healthz" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      echo "ERROR: the port-forward to argocd-server exited immediately." >&2
      sed 's/^/       /' "$TMP/pf.log" >&2
      echo "       (Is ARGOCD_LOCAL_PORT=${ARGOCD_LOCAL_PORT} already in use? Try a different one.)" >&2
      PF_PID=""
      exit 1
    fi
    sleep 1
  done
  echo "ERROR: timed out waiting for the port-forward to argocd-server to become ready." >&2
  exit 1
}

# token_is_valid TOKEN -- true if TOKEN authenticates as exactly the jenkins-cd account.
token_is_valid() {
  local tok="$1" code
  code="$(curl -sk -o "$TMP/userinfo.json" -w '%{http_code}' \
      -H "Authorization: Bearer ${tok}" "${BASE_URL}/api/v1/session/userinfo")" || return 1
  [ "$code" = "200" ] || return 1
  jq -e --arg acct "$ACCOUNT" \
      '.loggedIn == true and .username == $acct' "$TMP/userinfo.json" >/dev/null 2>&1
}

# ---- idempotency check ------------------------------------------------------------------------
if [ "${FORCE_ROTATE:-0}" != "1" ] && [ -n "$EXISTING_TOKEN" ]; then
  echo "${SECRET_ID} already holds an ARGOCD_AUTH_TOKEN (length ${#EXISTING_TOKEN}) -- checking whether it still authenticates."
  start_port_forward
  if token_is_valid "$EXISTING_TOKEN"; then
    echo "Existing token is valid for the '${ACCOUNT}' account -- leaving it in place, nothing changed."
    echo "(Set FORCE_ROTATE=1 to mint a new one anyway, e.g. after a leaked token.)"
    exit 0
  fi
  echo "Existing token no longer authenticates as '${ACCOUNT}' -- minting a replacement."
  unset EXISTING_TOKEN
fi

if [ "${FORCE_ROTATE:-0}" = "1" ]; then
  echo "FORCE_ROTATE=1 -- minting a new token regardless of what is currently stored."
fi

start_port_forward

# ---- admin session ------------------------------------------------------------------------------
# argocd-initial-admin-secret is created by the chart at install time and holds the one-time admin
# password. If it has been deleted (ArgoCD's own docs suggest doing so after first login), this
# fails closed with a clear message rather than guessing -- there is no other way for this script to
# authenticate as admin.
ADMIN_PASS="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>"$TMP/adminerr" | base64 -d)" || {
  echo "ERROR: could not read argocd-initial-admin-secret in namespace ${ARGOCD_NAMESPACE}." >&2
  sed 's/^/       /' "$TMP/adminerr" >&2
  echo "       Either the ArgoCD release has not been applied yet (terraform apply must run" >&2
  echo "       first -- this is the same ordering constraint as the jenkins-cd account itself)," >&2
  echo "       or the secret was deleted by hand after first login. If it's the latter, reset the" >&2
  echo "       admin password (argocd-cm / the ArgoCD CLI) and re-run this script." >&2
  exit 1
}
[ -n "$ADMIN_PASS" ] || { echo "ERROR: argocd-initial-admin-secret has no password." >&2; exit 1; }

SESSION_CODE="$(jq -n --arg u admin --arg p "$ADMIN_PASS" '{username:$u,password:$p}' \
    | curl -sk -o "$TMP/session.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' -X POST -d @- "${BASE_URL}/api/v1/session")"
unset ADMIN_PASS
if [ "$SESSION_CODE" != "200" ]; then
  echo "ERROR: ArgoCD admin login failed (HTTP ${SESSION_CODE})." >&2
  exit 1
fi
ADMIN_TOKEN="$(jq -r '.token // ""' "$TMP/session.json")"
[ -n "$ADMIN_TOKEN" ] || { echo "ERROR: ArgoCD login returned no token." >&2; exit 1; }
echo "Authenticated to ArgoCD as admin -- ok."

# ---- confirm the jenkins-cd account exists before trying to mint a token for it ------------------
# It is created by terraform apply of the ArgoCD release (accounts.jenkins-cd = apiKey in
# terraform/addon-argocd.tf), which on a fresh cluster runs AFTER this script could plausibly be
# called. Minting against a nonexistent account fails anyway, but with a confusing 404 -- this turns
# it into the actual ordering explanation.
ACCOUNT_CODE="$(curl -sk -o "$TMP/account.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" "${BASE_URL}/api/v1/account/${ACCOUNT}")"
if [ "$ACCOUNT_CODE" != "200" ]; then
  echo "ERROR: ArgoCD has no '${ACCOUNT}' local account yet (HTTP ${ACCOUNT_CODE})." >&2
  echo "       It is created by 'terraform apply' of the ArgoCD release" >&2
  echo "       (terraform/addon-argocd.tf's accounts.jenkins-cd = apiKey). Run that apply first," >&2
  echo "       then re-run this script." >&2
  ADMIN_TOKEN=""
  exit 1
fi

# ---- mint the token -------------------------------------------------------------------------------
TOKEN_CODE="$(curl -sk -o "$TMP/token.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
    -X POST -d '{}' "${BASE_URL}/api/v1/account/${ACCOUNT}/token")"
ADMIN_TOKEN=""
if [ "$TOKEN_CODE" != "200" ]; then
  echo "ERROR: minting a token for '${ACCOUNT}' failed (HTTP ${TOKEN_CODE})." >&2
  exit 1
fi
NEW_TOKEN="$(jq -r '.token // ""' "$TMP/token.json")"
[ -n "$NEW_TOKEN" ] || { echo "ERROR: ArgoCD returned no token in the mint response." >&2; exit 1; }
echo "Minted a new '${ACCOUNT}' token (length ${#NEW_TOKEN}) -- ok."

if ! token_is_valid "$NEW_TOKEN"; then
  echo "ERROR: the freshly minted token does not authenticate -- refusing to store it." >&2
  NEW_TOKEN=""
  exit 1
fi
echo "New token self-check passed -- ok."

# ---- merge into the secret, preserving the other five keys ---------------------------------------
jq --arg tok "$NEW_TOKEN" '.ARGOCD_AUTH_TOKEN = $tok' "$TMP/secret.json" > "$TMP/payload.json"
NEW_TOKEN=""

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --secret-string "file://$TMP/payload.json" \
  --query '[Name,VersionId]' --output text

echo "Stored. ${SECRET_ID} now carries the new ARGOCD_AUTH_TOKEN; the other five keys are unchanged."

# ---- force ESO to pick it up now, not on the next hourly refresh ---------------------------------
kubectl -n ci annotate externalsecret jenkins-secret force-sync="$(date +%s)" --overwrite
echo "Forced an ExternalSecret refresh."

# ---- restart the controller -- containerEnvFrom only reads the secret at pod start ---------------
# Not optional: a running controller never sees a key added after it booted, even once it's correct
# in both Secrets Manager and the synced Kubernetes Secret. Hit for real on 2026-08-04.
kubectl -n ci rollout restart statefulset jenkins
echo "Restarted the Jenkins controller so it picks up the new token."
echo
echo "Done. application-cd's Deploy stage should now authenticate."
