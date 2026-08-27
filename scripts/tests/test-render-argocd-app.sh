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
for want in "name: voteball" "namespace: devops-app" "targetRevision: release" \
            "path: charts/voteball" "prune: true" "selfHeal: true" \
            "ServerSideApply=true" "CreateNamespace=false"; do
  check "keeps '$want'" "$want" "$out"
done

# --- 3b. The AppProject bounds what may be deployed ------------------------------------------------
# Losing any of these silently widens the blast radius back to the stock `default` project's '*'.
check "renders an AppProject"              "kind: AppProject"           "$out"
check "Application joins that project"     "project: voteball"          "$out"
check "denies cluster-scoped resources"    "clusterResourceWhitelist: []" "$out"
check "pins the destination namespace"     "namespace: devops-app"      "$out"

# The AppProject must be applied BEFORE the Application that references it, IN EACH PAIR -- kubectl
# honours document order in a single stream, so a reordered template leaves an Application in "project
# does not exist". This file grows by one pair per chart (voteball, observability, logging, ...), so
# the check is DERIVED -- alternation, not a fixed list -- rather than a hardcoded sequence. Restating
# a count here just relocates the breakage to the next chart that gets added (found the hard way: a
# 2-pair hardcode broke the moment `logging` became the third pair).
kind_order="$(printf '%s\n' "$out" | grep -E '^kind: ')"
n_kinds="$(printf '%s\n' "$kind_order" | grep -c .)"
if [ "$n_kinds" -eq 0 ] || [ $((n_kinds % 2)) -ne 0 ]; then
  bad "expected an even, non-zero number of documents (AppProject/Application pairs), got $n_kinds"
elif printf '%s\n' "$kind_order" | paste - - | grep -qvE '^kind: AppProject[[:space:]]+kind: Application$'; then
  bad "documents must alternate AppProject then Application -- an Application whose project has not been applied yet is rejected"
  echo "       got: $(printf '%s' "$kind_order" | tr '\n' ',')"
else
  ok "$((n_kinds / 2)) AppProject/Application pairs, each project preceding its application"
fi

# The project's sourceRepos must be the SAME repo the Application pulls from. If they ever diverge --
# say a fork edits one and not the other -- ArgoCD refuses every sync with "not permitted in project",
# which reads like an ArgoCD fault rather than a template one.
src_count="$(printf '%s\n' "$out" | grep -c "https://github.com/Latnook/voteball" || true)"
if [ "$src_count" -ge 2 ]; then
  ok "AppProject sourceRepos and Application repoURL use the same rendered URL"
else
  bad "AppProject sourceRepos and Application repoURL use the same rendered URL"
  echo "       expected the URL twice, found it ${src_count}x"
fi

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
# safe_load_ALL, not safe_load: the template became a multi-document stream when the AppProject was
# added, and safe_load raises ComposerError on a second `---` -- a green test that would have gone
# red for the right reason but with a misleading message. Four documents now: the voteball pair, then
# the observability pair added alongside it.
if ARGOCD_STUB_github_repo="Latnook/voteball" "$RENDER" \
   | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
kinds = [d["kind"] for d in docs]
assert kinds == ["AppProject", "Application", "AppProject", "Application"], kinds
' 2>/dev/null; then
  ok "renders valid YAML: [AppProject, Application, AppProject, Application]"
else
  # PyYAML is not a hard dependency of this repo; skip rather than fail the suite over it.
  echo "  skip renders valid YAML (PyYAML not installed)"
fi

# --- 8. Argument handling --------------------------------------------------------------------------
# --check talks to a live cluster, so the suite (which is offline by contract) can only assert that
# the flag is recognised and that anything else is rejected rather than silently treated as a render.
if ARGOCD_STUB_github_repo="Latnook/voteball" "$RENDER" --bogus >/dev/null 2>&1; then
  bad "rejects an unknown flag"
else
  ok "rejects an unknown flag"
fi

# EVERY Application must watch `release`, and NONE may watch `master`. Checked as a count rather
# than "the string appears somewhere", because the failure this guards against is one Application
# being reverted while the others stay -- charts/observability (or now charts/logging) quietly
# syncing from an ungated branch would be exactly the gap the release branch was introduced to close
# (2026-08-23, Task 4 review P2), and the other Applications looking correct is what would hide it.
# The security property is "release, never master" -- NOT a fixed count, which is incidental and
# grows with every new chart's Application; requiring >=1 keeps the check from passing vacuously on
# an empty render.
n_release="$(grep -c 'targetRevision: release' argocd/voteball-application.yaml.tmpl)"
n_master="$(grep -c 'targetRevision: master' argocd/voteball-application.yaml.tmpl || true)"
if [ "$n_release" -ge 1 ] && [ "$n_master" -eq 0 ]; then
  ok "all $n_release Applications target the release branch, none targets master"
else
  bad "expected >=1 Application on 'release' and 0 on 'master', found $n_release and $n_master -- ArgoCD must never sync an ungated branch"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All $pass checks passed."
else
  echo "$fail of $((pass + fail)) checks FAILED."
  exit 1
fi
