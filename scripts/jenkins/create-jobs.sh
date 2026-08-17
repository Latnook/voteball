#!/usr/bin/env bash
# Ensures the two pipeline jobs exist, and ASSERTS it rather than printing something for a human to
# eyeball.
#
# This is a NAMED ENTRY POINT, not a job-creation mechanism. The course brief's section 2 lists a
# `create-jobs.sh`, and section 5 requires the jobs to be created FROM CODE (Job DSL / seed job /
# CLI / API -- "יצירה ידנית של jobs דרך Jenkins UI אינה עומדת בדרישות המשימה"). This repo satisfies
# that with the `jobs:` block of ci/jenkins/jenkins.yaml, which uses the Job DSL plugin's
# pipelineJob(...) syntax and is applied by the Helm release's controller.JCasC.configScripts at
# EVERY controller boot.
#
# So there is deliberately nothing here that creates a job. Anything that did would be a second,
# competing source of truth, and would lose: JCasC rebuilds the controller's configuration from that
# file on every restart -- roughly daily on a 100% Spot node group -- so a job created any other way
# is erased without warning. Creating jobs is `scripts/jenkins/configure-jenkins.sh`; this script
# proves the result.
#
# What it checks, and why each check earns its place:
#
#   1. Both jobs are DECLARED IN CODE. Grepped from ci/jenkins/jenkins.yaml, so this half works with
#      no cluster and no credentials -- it is a property of the repository.
#   2. Both jobs EXIST in the running controller, and no others do. The "no others" half matters:
#      Job DSL's removedJobAction defaults to `ignore`, so JCasC never deletes a job it stops
#      declaring. When the single `voteball` job was replaced by application-ci/application-cd, the
#      old one survived, red, pointing at a deleted Jenkinsfile, and had to be removed by hand.
#   3. Each job's definition points at the right Jenkinsfile in SCM (cpsScm), not at an inline
#      pipeline pasted into the controller.
#
# Usage:
#   scripts/jenkins/create-jobs.sh                     # repo checks + live checks (needs creds)
#   scripts/jenkins/create-jobs.sh --repo-only         # repo checks only, no cluster needed
#
# Credentials come from JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD (deploy.env supplies both).
set -uo pipefail

cd "$(dirname "$0")/../.."

JCASC=ci/jenkins/jenkins.yaml
EXPECTED_JOBS=(application-cd application-ci)   # sorted, to compare against the API's sorted list

REPO_ONLY=0
[ "${1:-}" = "--repo-only" ] && REPO_ONLY=1

status=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*" >&2; status=1; }

echo "=== jobs are declared in code (ci/jenkins/jenkins.yaml, Job DSL) ==="
for job in "${EXPECTED_JOBS[@]}"; do
  if grep -q "pipelineJob('${job}')" "$JCASC"; then
    ok "pipelineJob('${job}') is declared in $JCASC"
  else
    bad "pipelineJob('${job}') is NOT declared in $JCASC"
  fi
done

# The count must match too: a third pipelineJob would mean this script's expectations are stale.
declared="$(grep -cE "pipelineJob\('" "$JCASC")"
if [ "$declared" = "${#EXPECTED_JOBS[@]}" ]; then
  ok "exactly ${#EXPECTED_JOBS[@]} pipelineJob declarations, no more"
else
  bad "$JCASC declares $declared pipelineJob(s), expected ${#EXPECTED_JOBS[@]}"
fi

# Each job must load its Jenkinsfile FROM SCM. An inline definition would put pipeline logic in the
# controller's config instead of the repository, which is the thing section 3/4 require.
for f in Jenkinsfile-ci Jenkinsfile-cd; do
  if grep -q "scriptPath('${f}')" "$JCASC"; then
    ok "a job loads ${f} from SCM (cpsScm), not inline"
  else
    bad "no job references ${f} via scriptPath -- is the pipeline inline?"
  fi
  [ -f "$f" ] || bad "${f} does not exist in the repository"
done

if [ "$REPO_ONLY" = "1" ]; then
  echo
  [ "$status" -eq 0 ] && echo "create-jobs: repo checks passed (--repo-only; live controller not checked)"
  exit "$status"
fi

echo
echo "=== the same two jobs exist in the RUNNING controller, and nothing else does ==="

if [ -z "${JENKINS_ADMIN_USER:-}" ] || [ -z "${JENKINS_ADMIN_PASSWORD:-}" ]; then
  echo "  FAIL  no credentials: set JENKINS_ADMIN_USER and JENKINS_ADMIN_PASSWORD" >&2
  echo "        (or run with --repo-only to check the declarations alone)" >&2
  exit 1
fi

kubectl get namespace ci >/dev/null 2>&1 || {
  echo "  FAIL  cannot reach the cluster / namespace ci" >&2; exit 1; }

# The webhook Ingress exposes only /github-webhook, so the API is reachable only via port-forward.
pf_log="$(mktemp)"; netrc="$(mktemp)"; chmod 600 "$netrc"
kubectl port-forward -n ci svc/jenkins 0:8080 >"$pf_log" 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null; rm -f "$pf_log" "$netrc"' EXIT

port=""
for _ in $(seq 1 20); do
  port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' "$pf_log" | head -1)"
  [ -n "$port" ] && break
  sleep 0.5
done
[ -n "$port" ] || { echo "  FAIL  could not port-forward to svc/jenkins -n ci" >&2; exit 1; }

printf 'machine 127.0.0.1 login %s password %s\n' \
  "$JENKINS_ADMIN_USER" "$JENKINS_ADMIN_PASSWORD" >"$netrc"

api="$(curl -sS -g --netrc-file "$netrc" "http://127.0.0.1:${port}/api/json" 2>/dev/null)"
if [ -z "$api" ] || ! echo "$api" | jq -e . >/dev/null 2>&1; then
  echo "  FAIL  no valid JSON from Jenkins /api/json -- check credentials and that jenkins-0 is Ready" >&2
  exit 1
fi

live="$(echo "$api" | jq -r '[.jobs[]?.name] | sort | @json')"
want="$(printf '%s\n' "${EXPECTED_JOBS[@]}" | sort | jq -R . | jq -sc .)"
if [ "$live" = "$want" ]; then
  ok "the controller holds exactly $live"
else
  bad "the controller holds $live, expected $want -- a stale or missing job (Job DSL's removedJobAction defaults to 'ignore', so it never cleans these up)"
fi

echo
if [ "$status" -ne 0 ]; then
  echo "create-jobs: FAILURES ABOVE" >&2
  echo "             Jobs are created by JCasC -- fix ci/jenkins/jenkins.yaml, then run" >&2
  echo "             scripts/jenkins/configure-jenkins.sh. Do NOT create one in the UI." >&2
  exit 1
fi
echo "create-jobs: both jobs are declared in code and present in the controller."
