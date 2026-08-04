#!/usr/bin/env bash
# CD Smoke Test stage. The one check in this whole system that asks the PRODUCT whether it works.
#
# ArgoCD reports Healthy when pods pass their probes. Pods passing probes is not the same as the site
# serving a working page -- a backend that starts cleanly and 500s on every query is Healthy to
# ArgoCD and broken to a visitor. This script is the difference.
#
# Retries with a fixed delay because an ALB takes a few seconds to route to newly-Ready targets; a
# single immediate request would produce false failures and, since failure triggers a rollback, false
# rollbacks.
set -uo pipefail

: "${SMOKE_BASE_URL:?SMOKE_BASE_URL must be set (e.g. https://voteball.example.com)}"
retries="${SMOKE_RETRIES:-10}"
delay="${SMOKE_DELAY:-6}"

# Tests override this to run offline; production uses the real curl.
stub="${SMOKE_STUB_CURL:-}"

# A fixed path (the old /tmp/smoke-body) is shared by every container in the build pod; mktemp +
# trap keeps this invocation's body file private and guarantees cleanup on every exit path.
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

fetch() {
  if [ -n "$stub" ]; then
    "$stub" "$1"
  else
    # --max-time bounds a hung connection; without it a black-holed ALB makes the stage hang until
    # the pipeline timeout instead of failing and rolling back.
    curl -sS --max-time 15 -o "$body_file" -w '%{http_code} ' "$1" && cat "$body_file"
  fi
}

check() {
  local path="$1" want="$2" description="$3"
  local attempt=1 out code
  while [ "$attempt" -le "$retries" ]; do
    if out="$(fetch "${SMOKE_BASE_URL}${path}" 2>/dev/null)"; then
      # NR==1 only -- $out is "<code> <body...>" and a real page body is multi-line (nginx's
      # index.html, for one). Without this guard, awk prints field 1 of EVERY line joined by
      # newlines, "code" becomes "200\n<html>\n...", the comparison against "200" always fails, and
      # every real deploy would false-fail this check -- which triggers an automatic rollback of a
      # perfectly working deploy. Caught 2026-08-04 by code review before it ever ran against a real
      # multi-line body.
      code="$(printf '%s' "$out" | awk 'NR==1{print $1; exit}')"
      # An empty $want means "200 is enough" -- used for the HTML root, which has no JSON key to
      # match on.
      if [ "$code" = "200" ] && { [ -z "$want" ] || printf '%s' "$out" | grep -q "$want"; }; then
        echo "smoke: OK   ${path} (${description})"
        return 0
      fi
      echo "smoke: attempt ${attempt}/${retries} on ${path} -> ${code:-no-status}"
    else
      echo "smoke: attempt ${attempt}/${retries} on ${path} -> transport failure"
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$retries" ] && sleep "$delay"
  done
  echo "smoke: FAIL ${path} (${description}) after ${retries} attempts" >&2
  return 1
}

# ENDPOINT CHOICE, verified live on 2026-08-04 from a pod in the ci namespace.
#
# /health is NOT used, and that is deliberate twice over. First, it is not reachable: nginx proxies
# only /api/*, so /health from outside is a 404 -- it is the in-cluster probe target, nothing else.
# Second, and more importantly, /health is ALREADY what the kubelet probes and therefore what
# ArgoCD's health assessment is built on. Checking it here would re-ask a question ArgoCD has
# already answered, which is exactly the duplication this design avoids.
#
# What Jenkins asks instead is the question ArgoCD cannot: does the PUBLIC URL serve real data?
status=0
# The site itself, through the ALB and nginx. Proves the frontend is serving.
check / '' 'site root loads' || status=1
# Proves the backend is reachable through the proxy AND can read the database -- /api/options is
# unparameterised and returns seed data.
check /api/options 'clubs' 'options API reads the database' || status=1
# Proves the worker-computed rollup tables are readable, which is the deepest failure the other two
# cannot see. Requires the by= parameter; without it the API correctly returns 400.
check '/api/results?by=all' 'previous' 'results API reads the rollup tables' || status=1

[ "$status" -eq 0 ] && echo "smoke: all checks passed against ${SMOKE_BASE_URL}"
exit "$status"
