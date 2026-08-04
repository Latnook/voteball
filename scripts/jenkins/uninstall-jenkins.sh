#!/usr/bin/env bash
# Removes Jenkins from the cluster, leaving the application and its data untouched.
#
# The EFS filesystem's reclaim policy is Retain, so build history survives this and is picked up
# again on reinstall. `terraform destroy` (scripts/destroy.sh) removes the filesystem itself.
set -euo pipefail

cd "$(dirname "$0")/../../terraform"

echo "This removes the Jenkins release, its supporting chart and its Ingress."
echo "It does NOT touch devops-app, RDS, or the ArgoCD Application."
printf 'Type "yes" to continue: '
read -r reply
[ "$reply" = "yes" ] || { echo "Aborted."; exit 1; }

# jenkins_support last: its NetworkPolicies and ExternalSecret are what the controller needs while
# it shuts down.
terraform destroy -var-file=voteball.tfvars \
  -target=helm_release.jenkins \
  -target=helm_release.jenkins_support \
  "$@"

echo
echo "==> Removed. The EFS volume is retained; reinstall with scripts/jenkins/install-jenkins.sh"
