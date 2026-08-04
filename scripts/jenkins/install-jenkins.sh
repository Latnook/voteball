#!/usr/bin/env bash
# Installs Jenkins into the cluster.
#
# Jenkins is a PLATFORM ADD-ON owned by Terraform, not an application deployed by ArgoCD -- so this
# is a thin, honest wrapper around the Terraform resources that install it, not a second install
# path. A parallel install mechanism would be a lie about how this repo works, and would drift.
#
# Full deploy: scripts/deploy.sh. This script exists for the case where the cluster is already up
# and only the Jenkins add-on needs (re)installing.
set -euo pipefail

cd "$(dirname "$0")/../../terraform"

echo "==> Jenkins is installed by Terraform. Applying only the Jenkins-related resources."
echo "    Anything else that has drifted will NOT be corrected by this run."

terraform apply -var-file=voteball.tfvars \
  -target=aws_efs_file_system.jenkins \
  -target=aws_efs_mount_target.jenkins \
  -target=aws_eks_addon.efs_csi \
  -target=kubernetes_storage_class.efs \
  -target=helm_release.jenkins_support \
  -target=helm_release.jenkins \
  "$@"

echo
echo "==> Installed. Verify with:  scripts/jenkins/verify-jenkins.sh"
echo "==> Reach the UI with:       kubectl port-forward -n ci svc/jenkins 8080:8080"
echo "    (the UI is deliberately not internet-facing; only /github-webhook is routed)"
