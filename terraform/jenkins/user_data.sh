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
set -euxo pipefail

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
systemctl enable --now jenkins

# Re-running after the group change requires a Jenkins restart to pick up docker access.
systemctl restart jenkins

echo "BOOTSTRAP COMPLETE"
