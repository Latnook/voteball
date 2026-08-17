#!/usr/bin/env bash
# Pushes a Jenkins CONFIGURATION change (JCasC, plugins, credentials, agent pod templates, jobs) to
# the running controller.
#
# This is a NAMED ENTRY POINT onto the real mechanism, not a second configuration path. The course
# brief's section 2 lists a `configure-jenkins.sh` alongside install/verify, so it exists under that
# name; what it does is `terraform apply` of the Jenkins release, because that is genuinely how
# configuration reaches this controller.
#
# WHY IT IS terraform apply AND NOT A REST CALL OR A UI CLICK:
#
#   ci/jenkins/jenkins.yaml is loaded into the Helm release as controller.JCasC.configScripts and
#   applied by the chart's config-reload sidecar. Editing that file and COMMITTING IT CHANGES
#   NOTHING on its own -- Jenkins is a platform add-on owned by Terraform, the opposite of
#   charts/voteball, which ArgoCD syncs from master. Committing a JCasC change and walking away is
#   the single easiest mistake to make here, and it fails silently: the repo says one thing and the
#   running controller keeps doing another.
#
#   Equally, nothing configured by clicking in the UI survives. JCasC rebuilds the controller's
#   entire configuration from this file on every boot, and on a 100% Spot node group that is roughly
#   daily whether anyone touches it or not.
#
# So the correct workflow is: edit ci/jenkins/jenkins.yaml (or the Helm values in
# terraform/addon-jenkins.tf), commit, then run THIS.
#
# Usage:
#   scripts/jenkins/configure-jenkins.sh              # apply the config change
#   scripts/jenkins/configure-jenkins.sh --restart    # ...and force a controller restart afterwards
#
# --restart is needed for exactly one class of change: a NEW KEY in the voteball/jenkins secret.
# containerEnvFrom projects that Secret into the pod's environment at POD START, not continuously, so
# an already-running controller never sees a key added after it booted -- JCasC then logs
# "Found unresolved variable 'X'. Will default to empty string" and boots anyway, leaving a
# Jenkins-shaped controller with a job that silently has no credential. Nothing crashes.
set -euo pipefail

RESTART=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) RESTART=1 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Warn if the JCasC file has uncommitted changes. Not fatal -- applying local edits is a legitimate
# way to iterate -- but the applied configuration would then exist nowhere but this laptop, which is
# the same provenance problem build-push-ecr.sh's dirty-tree guard exists to prevent.
if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- ci/jenkins terraform/addon-jenkins.tf 2>/dev/null)" ]; then
  echo "WARNING: ci/jenkins/ or terraform/addon-jenkins.tf has uncommitted changes." >&2
  echo "         They WILL be applied, but the running controller would then match no commit." >&2
  echo "         Commit them so the cluster's configuration is reproducible from git." >&2
  echo >&2
fi

cd "$REPO_ROOT/terraform"

echo "==> Applying the Jenkins release (JCasC, plugins, credentials, agent templates, both jobs)."
echo "    Committing ci/jenkins/jenkins.yaml alone does NOT reach the cluster -- this step does."

terraform apply -var-file=voteball.tfvars \
  -target=helm_release.jenkins_support \
  -target=helm_release.jenkins \
  "${ARGS[@]+"${ARGS[@]}"}"

if [ "$RESTART" = "1" ]; then
  echo
  echo "==> Restarting the controller so it re-reads its projected environment (new secret keys)."
  kubectl rollout restart statefulset jenkins -n ci
  kubectl rollout status statefulset jenkins -n ci --timeout=300s
fi

echo
echo "==> Checking for the failure that does NOT crash: unresolved JCasC variables."
# JCasC does not fail fatally on an unresolved ${VAR}; it logs and boots. Treat any hit as a failed
# configuration even though the controller looks healthy.
if kubectl logs -n ci jenkins-0 -c jenkins --tail=2000 2>/dev/null | grep -i "unresolved variable"; then
  echo
  echo "ERROR: JCasC reported unresolved variable(s) above. The controller is RUNNING but a" >&2
  echo "       credential or setting is silently empty. If you just added a key to the" >&2
  echo "       voteball/jenkins secret, re-run with --restart." >&2
  exit 1
fi
echo "    none -- every JCasC variable resolved."

echo
echo "==> Configured. Verify with:  scripts/jenkins/verify-jenkins.sh"
echo "==> Confirm both jobs with:   scripts/jenkins/create-jobs.sh"
