#!/usr/bin/env bash
# Runs the course brief's section 10 checklist and ASSERTS on it, rather than printing output for a
# human to eyeball. Exits non-zero on the first structural failure.
#
# Every command below appears verbatim in the brief; the assertions are this repo's addition -- plus
# one assertion the brief does not have (see the two-jobs block below): JCasC's Job DSL does not
# delete jobs it no longer declares (removedJobAction defaults to "ignore"), so a stale job from a
# previous JCasC revision survives silently pointing at a deleted Jenkinsfile. Nothing else catches
# that; this does.
set -uo pipefail

status=0
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*" >&2; status=1; }
skip() { echo "  SKIP  $*"; }

echo "=== kubectl get namespaces ==="
kubectl get namespaces
kubectl get namespace ci >/dev/null 2>&1 && ok "the ci namespace exists" || bad "no ci namespace"
kubectl get namespace devops-app >/dev/null 2>&1 \
  && ok "the devops-app namespace exists" || bad "no devops-app namespace"

echo
echo "=== kubectl get pods -n ci -o wide ==="
kubectl get pods -n ci -o wide
ready="$(kubectl get pod jenkins-0 -n ci -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)"
case "$ready" in
  *false*|"") bad "the Jenkins controller is not Ready ($ready)" ;;
  *)          ok  "the Jenkins controller is Ready" ;;
esac

echo
echo "=== kubectl get service,ingress,pvc -n ci ==="
kubectl get service,ingress,pvc -n ci
# Named explicitly rather than .items[0] -- there is exactly one PVC in ci today (named "jenkins"),
# but indexing [0] would silently start checking the wrong volume the day that stops being true.
phase="$(kubectl get pvc jenkins -n ci -o jsonpath='{.status.phase}' 2>/dev/null)"
[ "$phase" = "Bound" ] && ok "the Jenkins home PVC (jenkins) is Bound" || bad "the jenkins PVC is '$phase', not Bound"

# The brief requires the UI not be open to the whole internet. This asserts the property directly:
# the Ingress must route the webhook path and nothing else.
paths="$(kubectl get ingress -n ci -o jsonpath='{.items[*].spec.rules[*].http.paths[*].path}')"
[ "$paths" = "/github-webhook" ] \
  && ok "the Ingress routes only /github-webhook -- the UI is not internet-facing" \
  || bad "the Ingress routes '$paths'; the Jenkins UI may be exposed"

echo
echo "=== kubectl get serviceaccount,role,rolebinding -n ci ==="
kubectl get serviceaccount,role,rolebinding -n ci
for sa in jenkins jenkins-agent jenkins-cd-agent; do
  kubectl get serviceaccount "$sa" -n ci >/dev/null 2>&1 \
    && ok "ServiceAccount $sa exists" || bad "ServiceAccount $sa is missing"
done

# The security claim, asserted rather than documented: CD may not write to the app namespace.
if kubectl auth can-i patch deployments \
     --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app 2>/dev/null | grep -q '^yes'; then
  bad "jenkins-cd-agent CAN patch deployments in devops-app -- it must be read-only"
else
  ok "jenkins-cd-agent cannot write to devops-app (ArgoCD is the only applier)"
fi
kubectl auth can-i list pods \
  --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app 2>/dev/null | grep -q '^yes' \
  && ok "jenkins-cd-agent can read devops-app for evidence and diagnostics" \
  || bad "jenkins-cd-agent cannot read devops-app"

echo
echo "=== helm list -n ci ==="
helm list -n ci
helm list -n ci -q | grep -qx jenkins && ok "the jenkins release is installed" || bad "no jenkins release"

echo
echo "=== Jenkins API: job list and numExecutors (needs JENKINS_ADMIN_USER/JENKINS_ADMIN_PASSWORD) ==="
# Both checks below need an authenticated call to Jenkins' own /api/json, which needs a route to the
# controller. The Ingress deliberately only exposes /github-webhook (asserted above), so the only way
# in is a port-forward -- started here, torn down in a trap so a failure partway through this block
# (or anywhere later in the script) can never leave it running.
#
# GETs need no CSRF crumb -- Jenkins only enforces the crumb+session-cookie pair on state-changing
# requests -- so plain HTTP basic auth via curl -u is enough; no cookie jar required.
if [ -z "${JENKINS_ADMIN_USER:-}" ] || [ -z "${JENKINS_ADMIN_PASSWORD:-}" ]; then
  skip "job list / numExecutors checks (no credentials: set JENKINS_ADMIN_USER and JENKINS_ADMIN_PASSWORD)"
else
  pf_log="$(mktemp)"
  kubectl port-forward -n ci svc/jenkins 0:8080 >"$pf_log" 2>&1 &
  pf_pid=$!
  trap 'kill "$pf_pid" 2>/dev/null || true; rm -f "$pf_log"' EXIT

  local_port=""
  for _ in $(seq 1 20); do
    local_port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' "$pf_log" | head -1)"
    [ -n "$local_port" ] && break
    sleep 0.5
  done

  if [ -z "$local_port" ]; then
    bad "could not establish a port-forward to svc/jenkins -n ci for the credentialed checks"
  else
    api_json="$(curl -s -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
      "http://127.0.0.1:${local_port}/api/json" 2>/dev/null)"

    if [ -z "$api_json" ] || ! echo "$api_json" | jq -e . >/dev/null 2>&1; then
      bad "no valid JSON from Jenkins /api/json -- check credentials and that jenkins-0 is Ready"
    else
      # Exactly these two jobs, no more, no fewer, no stale leftovers. This is the assertion that
      # would have caught the surviving "voteball" job: removedJobAction defaults to "ignore", so
      # JCasC's Job DSL never deletes a job it stops declaring -- a human has to notice and remove it.
      jobs="$(echo "$api_json" | jq -r '[.jobs[]?.name] | sort | @json')"
      expected='["application-cd","application-ci"]'
      if [ "$jobs" = "$expected" ]; then
        ok "exactly the two expected jobs exist: $jobs"
      else
        bad "job list is $jobs, expected $expected -- a stale or missing job (removedJobAction: ignore does not clean these up)"
      fi

      # numExecutors from /api/json rather than grepping config.xml inside the pod -- the file's
      # tag layout is an implementation detail liable to change across chart versions, while this
      # field is the documented API contract.
      execs="$(echo "$api_json" | jq -r '.numExecutors // empty')"
      if [ "$execs" = "0" ]; then
        ok "numExecutors is 0 -- the controller runs no builds"
      elif [ -z "$execs" ]; then
        bad "could not read numExecutors from /api/json"
      else
        bad "numExecutors is $execs, not 0 -- builds could run on the controller"
      fi
    fi
  fi

  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
  rm -f "$pf_log"
  trap - EXIT
fi

echo
[ "$status" -eq 0 ] && echo "verify-jenkins: ALL CHECKS PASSED" || echo "verify-jenkins: FAILURES ABOVE" >&2
exit "$status"
