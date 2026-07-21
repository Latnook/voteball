#!/usr/bin/env bash
# First-boot bootstrap for the Jenkins build host.
#
# IMPORTANT: user_data runs ONCE, on first boot, and Terraform does NOT check whether it succeeded --
# `terraform apply` reports success as long as the instance was created. A failure here surfaces only
# as a missing service. Output goes to /var/log/cloud-init-output.log.
#
# This script is deliberately IDEMPOTENT so you can iterate over SSH by re-running it directly
# instead of destroying and recreating the instance for each attempt:
#     sudo bash /var/lib/cloud/instance/user-data.txt
#
# Trivy is NOT installed: it runs as a container (aquasec/trivy:0.58.1), exactly as the retired
# GitHub Actions pipeline did, so the pinned version stays visible in the Jenkinsfile.
#
# Terraform prepends a generated header (user_data_env.sh.tftpl) exporting VOTEBALL_REGION,
# VOTEBALL_CLUSTER and VOTEBALL_GITHUB_REPO. The defaults below only apply when running this file
# directly during development.
set -euxo pipefail

# These two fallbacks MUST match the defaults in variables.tf (same rule as scripts/lib/config.sh).
: "${VOTEBALL_REGION:=il-central-1}"
: "${VOTEBALL_CLUSTER:=voteball}"
: "${VOTEBALL_GITHUB_REPO:?VOTEBALL_GITHUB_REPO must be set (owner/repo)}"

dnf update -y

# Jenkins requires Java 17+; 21 is the current LTS on AL2023.
dnf install -y java-21-amazon-corretto-headless git docker

# Jenkins is not in the AL2023 repositories.
if [ ! -f /etc/yum.repos.d/jenkins.repo ]; then
  curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo
fi
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# Lets Jenkins build images. NOTE: docker group membership is effectively root on this host, so
# anyone who can define a Jenkins job can control the machine. Inherent to building containers on a
# Jenkins agent; mitigated by there being no inbound access except GitHub's webhook. See
# docs/security.md.
usermod -aG docker jenkins

# Persist Trivy's ~50MB vulnerability database between builds. Without this the --rm container
# re-downloads it on every scan (four times per build), which is slow and risks anonymous-pull rate
# limits on ghcr.io failing builds for reasons unrelated to the code.
install -d -o jenkins -g jenkins /var/lib/trivy-cache

systemctl enable --now docker

# ------------------------------------------------------------------------------------------------
# Jenkins Configuration as Code
#
# Everything below replaces the 12-step click-through runbook that used to follow `terraform apply`.
# The configuration itself is terraform/jenkins/casc/jenkins.yaml IN THIS REPOSITORY; the host
# fetches it, so "what is this Jenkins configured to do" is answered by reading git, not by logging
# in. Re-running this script re-applies it, which is the update path.
# ------------------------------------------------------------------------------------------------
CASC_DIR=/var/lib/jenkins/casc
SECRETS_DIR=/var/lib/jenkins/casc-secrets

# 1. Fetch the configuration from the repository.
#
# Uses HTTPS and no credentials: the repo is public, which is what makes this possible at all -- the
# deploy key needed to clone privately is itself one of the secrets JCasC installs, so a private
# repo here would be a genuine chicken-and-egg. If this repository is ever made private, this step
# must move to baking the files into user_data instead.
install -d -o jenkins -g jenkins "$CASC_DIR"
CASC_TMP="$(mktemp -d)"
git clone --depth 1 --branch master "https://github.com/${VOTEBALL_GITHUB_REPO}.git" "$CASC_TMP/repo"
install -o jenkins -g jenkins -m 0644 "$CASC_TMP/repo/terraform/jenkins/casc/jenkins.yaml" "$CASC_DIR/jenkins.yaml"
install -o jenkins -g jenkins -m 0644 "$CASC_TMP/repo/terraform/jenkins/casc/plugins.txt" "$CASC_DIR/plugins.txt"
rm -rf "$CASC_TMP"

# 2. Install exactly the plugins in plugins.txt (dependencies resolved automatically).
#
# The RPM does not ship jenkins-plugin-cli, so fetch the plugin manager jar. Pinned: an unpinned
# tool that installs plugins is two moving parts, not one.
PLUGIN_MGR=/opt/jenkins-plugin-manager.jar
PLUGIN_MGR_VERSION=2.13.2
if [ ! -f "$PLUGIN_MGR" ]; then
  curl -fsSL -o "$PLUGIN_MGR" \
    "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MGR_VERSION}/jenkins-plugin-manager-${PLUGIN_MGR_VERSION}.jar"
fi
java -jar "$PLUGIN_MGR" \
  --war /usr/share/java/jenkins.war \
  --plugin-file "$CASC_DIR/plugins.txt" \
  --plugin-download-directory /var/lib/jenkins/plugins \
  --latest true
chown -R jenkins:jenkins /var/lib/jenkins/plugins

# 3. Materialise the secrets JCasC will interpolate.
#
# One file per value, read by JCasC's file-based secret source (SECRETS env var below). Files rather
# than environment variables because the deploy key is MULTI-LINE and its trailing newline is
# load-bearing -- systemd's EnvironmentFile cannot carry either faithfully, and a key that lost its
# trailing newline fails as "Permission denied (publickey)", which reads like an auth problem and
# is not (docs/cicd.md, failure mode 2).
install -d -m 0700 -o jenkins -g jenkins "$SECRETS_DIR"
aws secretsmanager get-secret-value \
  --secret-id "${VOTEBALL_CLUSTER}/jenkins" \
  --region "$VOTEBALL_REGION" \
  --query SecretString --output text \
| python3 -c '
import json, os, sys
target = sys.argv[1]
data = json.load(sys.stdin)
if "placeholder" in data:
    raise SystemExit("FATAL: the secret still holds its Terraform placeholder. "
                     "Seed it with scripts/seed-jenkins-secret.sh before booting Jenkins.")
for key, value in data.items():
    path = os.path.join(target, key)
    # Written byte-for-byte: no strip(), no added newline.
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(value)
    os.chmod(path, 0o400)
print("JCasC secrets written:", sorted(data))
' "$SECRETS_DIR"
chown -R jenkins:jenkins "$SECRETS_DIR"

# 4. Point Jenkins at all of it, and skip the setup wizard.
#
# runSetupWizard=false is what stops a JCasC-configured Jenkins from booting into "unlock Jenkins
# with the password from disk" -- with an admin user already defined in jenkins.yaml, that screen
# would be a dead end on a host whose UI is only reachable through a tunnel.
install -d /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/casc.conf <<CASC
[Service]
Environment="CASC_JENKINS_CONFIG=${CASC_DIR}/jenkins.yaml"
Environment="SECRETS=${SECRETS_DIR}"
Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false"
Environment="AWS_REGION=${VOTEBALL_REGION}"
Environment="CLUSTER_NAME=${VOTEBALL_CLUSTER}"
Environment="GITHUB_REPO=${VOTEBALL_GITHUB_REPO}"
CASC
systemctl daemon-reload

# github.com's host keys must be known before the first SSH checkout, or it fails outright.
install -d -o jenkins -g jenkins -m 0700 /var/lib/jenkins/.ssh
ssh-keyscan github.com > /var/lib/jenkins/.ssh/known_hosts 2>/dev/null
chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts
chmod 0644 /var/lib/jenkins/.ssh/known_hosts

systemctl enable --now jenkins

# Re-running after the group change requires a Jenkins restart to pick up docker access, and any
# re-run needs one anyway to re-apply the configuration above.
systemctl restart jenkins

echo "BOOTSTRAP COMPLETE"
