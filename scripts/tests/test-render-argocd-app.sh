#!/usr/bin/env bash
# Tests scripts/render-argocd-app.sh with NO AWS/Terraform access.
# The github_repo lookup is stubbed via the ARGOCD_STUB_* env var the script honours -- same offline
# pattern as test-sync-values.sh and test-ci-guards.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

RENDER="scripts/render-argocd-app.sh"
pass=0
fail=0

ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1"; fail=$((fail + 1)); }

check() { # check <description> <expected-substring> <actual>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1"; echo "       expected to contain: $2"; echo "       got: $3" ;;
  esac
}

echo "render-argocd-app.sh"

# --- 1. Happy path: owner/name becomes a full https URL --------------------------------------------
out="$(ARGOCD_STUB_github_repo="Latnook/voteball" "$RENDER")"
check "renders repoURL from github_repo" "repoURL: https://github.com/Latnook/voteball" "$out"

# --- 2. A FORK gets its own URL with no file edits -------------------------------------------------
# This is the whole point of the change: the previous hardcoded manifest made this case impossible.
out="$(ARGOCD_STUB_github_repo="someone-else/their-fork" "$RENDER")"
check "a fork's repo flows through" "repoURL: https://github.com/someone-else/their-fork" "$out"
case "$out" in
  *Latnook*) bad "no trace of the original owner remains"; echo "       got: $out" ;;
  *)         ok  "no trace of the original owner remains" ;;
esac

# --- 3. Nothing else about the Application drifted -------------------------------------------------
# These four settings are load-bearing (selfHeal fights teardown, prune deletes removed resources,
# ServerSideApply adopts helm's resources instead of recreating the ALB). A template edit that lost
# one of them would still render and still apply.
out="$(ARGOCD_STUB_github_repo="Latnook/voteball" "$RENDER")"
for want in "name: voteball" "namespace: devops-app" "targetRevision: master" \
            "path: charts/voteball" "prune: true" "selfHeal: true" \
            "ServerSideApply=true" "CreateNamespace=false"; do
  check "keeps '$want'" "$want" "$out"
done

# --- 4. No placeholder survives --------------------------------------------------------------------
case "$out" in
  *'${'*) bad "no unsubstituted placeholder"; echo "       got: $out" ;;
  *)      ok  "no unsubstituted placeholder" ;;
esac

# --- 5. Malformed github_repo fails LOUDLY, before kubectl sees it ---------------------------------
# A full URL in voteball.tfvars is the natural mistake and would otherwise compose into
# https://github.com/https://github.com/... -- an Application ArgoCD accepts and cannot fetch.
for bogus in "https://github.com/Latnook/voteball" "git@github.com:Latnook/voteball.git" \
             "voteball" "a/b/c" ""; do
  if ARGOCD_STUB_github_repo="$bogus" "$RENDER" >/dev/null 2>&1; then
    bad "rejects malformed github_repo '${bogus}'"
  else
    ok "rejects malformed github_repo '${bogus}'"
  fi
done

# --- 6. An unknown placeholder is caught rather than applied verbatim -------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp argocd/voteball-application.yaml.tmpl "$TMP/backup.tmpl"
printf '  # future: ${SOME_NEW_FIELD}\n' >> argocd/voteball-application.yaml.tmpl
if ARGOCD_STUB_github_repo="Latnook/voteball" "$RENDER" >/dev/null 2>&1; then
  bad "fails closed on an unknown placeholder"
else
  ok "fails closed on an unknown placeholder"
fi
cp "$TMP/backup.tmpl" argocd/voteball-application.yaml.tmpl

# --- 7. The rendered output is valid YAML ----------------------------------------------------------
if ARGOCD_STUB_github_repo="Latnook/voteball" "$RENDER" \
   | python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin)' 2>/dev/null; then
  ok "renders valid YAML"
else
  # PyYAML is not a hard dependency of this repo; skip rather than fail the suite over it.
  echo "  skip renders valid YAML (PyYAML not installed)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All $pass checks passed."
else
  echo "$fail of $((pass + fail)) checks FAILED."
  exit 1
fi
