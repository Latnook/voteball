#!/usr/bin/env bash
# Removes Jenkins from the cluster, leaving the application untouched.
#
# This does NOT preserve build history across a reinstall, and does not need to: the jenkins/jenkins
# chart's PVC carries no `helm.sh/resource-policy: keep` annotation, so `terraform destroy
# -target=helm_release.jenkins` deletes the jenkins-0 PVC along with the release. What survives is the
# EFS filesystem and the data on it, because the efs-sc StorageClass's reclaim policy is Retain
# (terraform/addon-efs.tf) -- deleting the PVC leaves the PV in a Released state and the EFS access
# point's data intact, it does not delete either. But a reinstall provisions a brand-new PVC and a new
# dynamic access point; it does NOT rebind to the released one. Recovering the previous build history
# after a reinstall means manually rebinding the Released PV (or pointing a new PVC at the old access
# point) -- nothing here does that automatically. `terraform destroy` on the EFS resources themselves
# (full teardown, scripts/destroy.sh) deletes the filesystem, and with it the data, for good.
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
echo "==> Removed. The EFS filesystem and its data survive (efs-sc reclaim policy is Retain), but the"
echo "    PVC is gone -- reinstall with scripts/jenkins/install-jenkins.sh will provision a NEW, EMPTY"
echo "    volume. It does not rebind to the old one; recovering prior build history needs a manual PV"
echo "    rebind (or pointing a new PVC at the old EFS access point), not just a reinstall."
