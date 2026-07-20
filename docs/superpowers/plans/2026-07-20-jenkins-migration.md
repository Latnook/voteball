# Jenkins Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the GitHub Actions CI pipeline with Jenkins running on a dedicated EC2 host, without changing how the application is deployed.

**Architecture:** A new, independently-applied Terraform stack (`terraform/jenkins/`) creates one EC2 instance whose IAM instance profile grants ECR push and nothing else. Jenkins builds, scans and pushes the four images, then commits the new image tag to `master`; ArgoCD observes that commit and rolls the Deployments exactly as it does today. Jenkins never holds cluster credentials.

**Tech Stack:** Terraform (`aws ~> 5.0`, `http ~> 3.4`), Amazon Linux 2023, Jenkins LTS (declarative pipeline), Docker, Trivy 0.58.1 (container), Bash.

**Spec:** `docs/design/2026-07-20-jenkins-migration-design.md`. Section references below (§1–§10, G1–G7) point into it.

## Global Constraints

- **No hardcoded identity anywhere.** Region, account, cluster name and domain come from variables or `data` sources. A hardcoded ARN, bucket, registry or domain is a bug (`CLAUDE.md`).
- **Region:** `il-central-1`. **Cluster/resource prefix:** `voteball`. **Account:** `590183895228` (resolved via `data.aws_caller_identity`, never written literally). **Repo:** `Latnook/voteball`.
- **Run `terraform fmt -recursive` before committing any `.tf` change.**
- **Commit and push as you go** (`CLAUDE.md` standing instruction). Never force-push.
- **`terraform apply` creates billed resources.** Tasks 3 and 8 must stop for explicit human confirmation before running it.
- **Do not touch `terraform/eks.tf` or `terraform/irsa.tf`.** Their OIDC references are the *cluster's* IRSA provider and are unrelated to GitHub (§3 hazard).
- **Do not modify** `charts/`, `argocd/`, `services/`, `scripts/deploy.sh`, `scripts/destroy.sh`, `scripts/sync-values-from-tf.sh`.
- **Cutover ordering is mandatory** (§10): GitHub Actions must be disarmed *before* the Jenkins webhook is enabled, and `terraform/github-oidc.tf` is deleted **last**, as its own commit, after verification.

## Deviation from the spec

§7 describes the G1 and G2 logic as inline `Jenkinsfile` shell. This plan extracts both into `scripts/ci/*.sh` so they can be unit-tested offline, following the established precedent of `scripts/sync-values-from-tf.sh` + `scripts/tests/test-sync-values.sh` (which stubs its external lookups via `SYNC_STUB_*` env vars). The `Jenkinsfile` still owns every build, scan and push stage; only the two decision helpers move. Rationale: pipeline logic that can only be tested by triggering real builds is exactly what G2 makes dangerous.

## File Structure

| File | Responsibility |
|---|---|
| `.gitignore` | **Modified.** Ignore the new stack's state, tfvars, plan and provider cache |
| `terraform/jenkins/versions.tf` | Provider requirements and pins |
| `terraform/jenkins/variables.tf` | Inputs: region, cluster_name, admin_cidr, public_key_path, instance_type |
| `terraform/jenkins/iam.tf` | Role, instance profile, ECR-push policy |
| `terraform/jenkins/main.tf` | Data lookups, key pair, security group, instance, Elastic IP |
| `terraform/jenkins/outputs.tf` | Public IP, SSH tunnel command, webhook URL |
| `terraform/jenkins/user_data.sh` | First-boot bootstrap (idempotent) |
| `terraform/jenkins/jenkins.tfvars.example` | Template for the gitignored tfvars |
| `terraform/jenkins/README.md` | What this stack is, why it is separate, how to apply |
| `scripts/ci/should-skip-build.sh` | G2 — decide whether a commit is Jenkins' own |
| `scripts/ci/images-exist.sh` | G1 — decide whether this SHA is already in ECR |
| `scripts/tests/test-ci-guards.sh` | Offline tests for both helpers |
| `Jenkinsfile` | Pipeline: guard, checkout, build, scan, push, bump |
| `.github/workflows/ci.yml` | **Disarmed (Task 9), then deleted (Task 10)** |
| `terraform/github-oidc.tf` | **Deleted last (Task 11)** |
| `terraform/outputs.tf:56-58` | **Modified (Task 11)** — remove `github_actions_role_arn` |
| `docs/cicd.md` | **Rewritten (Task 12)** |
| `docs/eks/architecture.md:43,71` | **Modified (Task 12)** — graded diagram |
| `README.submission.md:46` | **Modified (Task 12)** — graded deliverable |
| `CLAUDE.md`, `README.md`, `docs/security.md`, `docs/maintenance.md`, `docs/production-readiness.md` | **Modified (Task 12)** |

---

### Task 1: Close the `.gitignore` gap (§2)

Do this **first**, before any Terraform file exists, so no state file can ever be staged.

**Files:**
- Modify: `.gitignore:14-20`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test-gitignore.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
for p in terraform/jenkins/terraform.tfstate \
         terraform/jenkins/terraform.tfstate.1784477786.backup \
         terraform/jenkins/jenkins.tfvars \
         terraform/jenkins/tfplan \
         terraform/jenkins/.terraform/providers; do
  git check-ignore -q "$p" || { echo "FAIL: $p is NOT ignored"; exit 1; }
done
echo "PASS: all jenkins stack artifacts ignored"
EOF
chmod +x /tmp/test-gitignore.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/test-gitignore.sh`
Expected: `FAIL: terraform/jenkins/terraform.tfstate is NOT ignored`

- [ ] **Step 3: Add the rules**

Append to `.gitignore` immediately after the existing `terraform/snapshot.auto.tfvars` line:

```gitignore

# The Jenkins build host is a SEPARATE stack with its own state, applied and destroyed
# independently of terraform/ so that destroy.sh cannot delete CI. The rules above are anchored to
# terraform/ and do NOT match this subdirectory.
terraform/jenkins/jenkins.tfvars
terraform/jenkins/terraform.tfstate*
terraform/jenkins/.terraform/
terraform/jenkins/tfplan
```

- [ ] **Step 4: Run it to verify it passes**

Run: `/tmp/test-gitignore.sh`
Expected: `PASS: all jenkins stack artifacts ignored`

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "gitignore: cover the new terraform/jenkins stack

The existing rules are anchored to terraform/ and do not match the
subdirectory, so the Jenkins stack's state file would be tracked on the
first git add."
git push origin master
```

---

### Task 2: Terraform stack — variables, providers, IAM (§1, §3)

**Files:**
- Create: `terraform/jenkins/versions.tf`, `terraform/jenkins/variables.tf`, `terraform/jenkins/iam.tf`, `terraform/jenkins/jenkins.tfvars.example`

**Interfaces:**
- Produces: `aws_iam_instance_profile.jenkins` (consumed by `main.tf` in Task 3); variables `region`, `cluster_name`, `admin_cidr`, `public_key_path`, `instance_type`.

- [ ] **Step 1: Create `terraform/jenkins/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region = var.region
}
```

- [ ] **Step 2: Create `terraform/jenkins/variables.tf`**

```hcl
variable "region" {
  description = "AWS region. Must match the region holding the ECR repositories."
  type        = string
  default     = "il-central-1"
}

variable "cluster_name" {
  description = "Resource name prefix, matching the main stack. Also selects which ECR repositories this host may push to (<cluster_name>-*)."
  type        = string
  default     = "voteball"
}

variable "admin_cidr" {
  description = "CIDR permitted to SSH (port 22). Your home IP as a /32. Update and re-apply when your ISP reassigns it."
  type        = string
}

variable "public_key_path" {
  description = "Path to the PUBLIC half of the voteball-jenkins key pair. The private .pem never leaves your machine."
  type        = string
}

variable "instance_type" {
  description = "t3.medium (4GB) is the floor: four Docker builds plus Trivy's vulnerability database do not fit in 2GB."
  type        = string
  default     = "t3.medium"
}
```

- [ ] **Step 3: Create `terraform/jenkins/iam.tf`**

```hcl
# The build host authenticates to AWS via this role, attached to the instance itself -- no OIDC
# federation and no stored keys. Permissions are lifted verbatim from the retired
# terraform/github-oidc.tf: ECR push, and nothing else. No EKS, RDS, S3, SNS or Secrets Manager.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken is account-wide by design
  }
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    # Written as an ARN pattern rather than a reference to the main stack's repositories, so this
    # stack has no cross-stack dependency and applies cleanly while the cluster is destroyed.
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-*"
    ]
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.cluster_name}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "jenkins_ecr" {
  name   = "${var.cluster_name}-jenkins-ecr"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_ecr.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.cluster_name}-jenkins"
  role = aws_iam_role.jenkins.name
}
```

> `ecr:DescribeImages` is additional to the GitHub Actions policy. G1's "already built?" check needs it.

- [ ] **Step 4: Create `terraform/jenkins/jenkins.tfvars.example`**

```hcl
# Copy to jenkins.tfvars (gitignored) and fill in.
# admin_cidr      = "203.0.113.45/32"   # curl -s https://checkip.amazonaws.com
# public_key_path = "~/.ssh/voteball-jenkins.pub"
# region          = "il-central-1"
# cluster_name    = "voteball"
```

- [ ] **Step 5: Verify it parses**

```bash
cd terraform/jenkins && terraform init -backend=false && terraform fmt -recursive && terraform validate
```
Expected: `Success! The configuration is valid.` (`main.tf` does not exist yet; validate passes because nothing references the instance.)

- [ ] **Step 6: Commit**

```bash
git add terraform/jenkins/
git commit -m "terraform/jenkins: variables, providers and ECR-push IAM role

Separate stack with its own state so destroy.sh cannot delete CI. The
ECR policy is scoped by ARN pattern rather than by resource reference,
so this stack has no dependency on the main one and applies while the
cluster is destroyed."
git push origin master
```

---

### Task 3: Terraform stack — network and instance (§4, §5)

**Files:**
- Create: `terraform/jenkins/main.tf`, `terraform/jenkins/outputs.tf`

**Interfaces:**
- Consumes: `aws_iam_instance_profile.jenkins` (Task 2), `var.admin_cidr`, `var.public_key_path`, `var.instance_type`.
- Produces: outputs `jenkins_url`, `ssh_tunnel_command`, `webhook_url`, `instance_id`.

- [ ] **Step 1: Create `terraform/jenkins/main.tf`**

```hcl
# Deployed into the region's DEFAULT VPC, deliberately NOT the application VPC, so the two
# lifecycles never touch: scripts/destroy.sh tears down the application VPC on every rebuild cycle.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# GitHub publishes its webhook source ranges and changes them periodically. Fetching at apply time
# means a re-apply refreshes them; hardcoding would mean a webhook that silently stops firing.
data "http" "github_meta" {
  url = "https://api.github.com/meta"
}

locals {
  github_hook_cidrs = [
    for c in jsondecode(data.http.github_meta.response_body)["hooks"] : c
    if !strcontains(c, ":") # IPv4 only; the instance has no IPv6 address
  ]
}

resource "aws_key_pair" "jenkins" {
  key_name   = "${var.cluster_name}-jenkins"
  public_key = file(var.public_key_path)
}

resource "aws_security_group" "jenkins" {
  name        = "${var.cluster_name}-jenkins"
  description = "Jenkins build host: webhook from GitHub, SSH from the maintainer"
  vpc_id      = data.aws_vpc.default.id

  # The ONLY thing in the world that may initiate a connection to this host besides the maintainer.
  # The Jenkins UI is not reachable this way -- it is reached through the SSH tunnel, whose traffic
  # arrives from localhost and is never evaluated against this group.
  ingress {
    description = "GitHub push webhooks"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = local.github_hook_cidrs
  }

  ingress {
    description = "SSH from the maintainer, for the UI tunnel"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Unrestricted egress: ECR, GitHub, Docker Hub, ghcr.io (Trivy's vulnerability database) and the
  # OS package repositories all publish wide, shifting ranges. An allowlist here would be brittle
  # rather than secure. Documented as an accepted position in docs/security.md.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-jenkins" }
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  key_name               = aws_key_pair.jenkins.key_name
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  user_data              = file("${path.module}/user_data.sh")

  # IMDSv2 required: without it a server-side request forgery on this host could read the
  # instance profile's credentials, which carry ECR push.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.cluster_name}-jenkins" }
}

# So the address survives the stop/start cycles that keep this host at ~$2.50/mo when idle.
resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"
  tags     = { Name = "${var.cluster_name}-jenkins" }
}
```

- [ ] **Step 2: Create `terraform/jenkins/outputs.tf`**

```hcl
output "instance_id" {
  description = "For `aws ec2 stop-instances --instance-ids <id>` between working sessions."
  value       = aws_instance.jenkins.id
}

output "jenkins_public_ip" {
  description = "Elastic IP. Stable across stop/start."
  value       = aws_eip.jenkins.public_ip
}

output "ssh_tunnel_command" {
  description = "Run this, then browse http://localhost:8080. The UI is not publicly reachable."
  value       = "ssh -i ~/.ssh/${var.cluster_name}-jenkins.pem -L 8080:localhost:8080 ec2-user@${aws_eip.jenkins.public_ip}"
}

output "webhook_url" {
  description = "Paste into GitHub > Settings > Webhooks. The trailing slash is required."
  value       = "http://${aws_eip.jenkins.public_ip}:8080/github-webhook/"
}
```

- [ ] **Step 3: Verify it parses (no apply yet)**

```bash
cd terraform/jenkins && terraform fmt -recursive && terraform validate
```
Expected: `Success! The configuration is valid.`

> `user_data.sh` does not exist yet, so `validate` passes but `plan` would fail on `file()`. That is expected; Task 4 creates it.

- [ ] **Step 4: Commit**

```bash
git add terraform/jenkins/
git commit -m "terraform/jenkins: security group, instance and Elastic IP

Exactly one inbound entry that is not the maintainer's: GitHub's webhook
CIDRs, fetched from api.github.com/meta at apply time. The Jenkins UI is
reached through an SSH tunnel, so it is never publicly exposed. IMDSv2
required so an SSRF cannot read the ECR-push credentials."
git push origin master
```

---

### Task 4: Bootstrap script (§6)

**Files:**
- Create: `terraform/jenkins/user_data.sh`, `terraform/jenkins/README.md`

- [ ] **Step 1: Create `terraform/jenkins/user_data.sh`**

```bash
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
```

- [ ] **Step 2: Lint it**

```bash
bash -n terraform/jenkins/user_data.sh && shellcheck terraform/jenkins/user_data.sh || true
```
Expected: no syntax errors. (`shellcheck` may be absent; `bash -n` is the gate.)

- [ ] **Step 3: Create `terraform/jenkins/README.md`**

````markdown
# Jenkins build host

A **separate Terraform stack with its own state**, applied and destroyed independently of
`terraform/`.

## Why it is separate

`scripts/destroy.sh` tears down the application stack on every rebuild cycle. A CI server owned by
that stack would be deleted — along with its build history and configuration — every time. This stack
also has **no reference to the main one**: its ECR permission is an ARN pattern, so it applies cleanly
while the cluster is destroyed.

## Apply

```bash
ssh-keygen -t ed25519 -f ~/.ssh/voteball-jenkins -C voteball-jenkins   # once
cp jenkins.tfvars.example jenkins.tfvars                               # fill in admin_cidr
terraform init
terraform apply -var-file=jenkins.tfvars
```

`admin_cidr` is your home IP as a `/32` (`curl -s https://checkip.amazonaws.com`). Update it and
re-apply when your ISP reassigns you.

## Reach the UI

The Jenkins UI is **not publicly reachable**. Only GitHub's webhook CIDRs can reach port 8080.

```bash
terraform output -raw ssh_tunnel_command   # then browse http://localhost:8080
```

## Cost

About **$30/month** running. Stop it between sessions:

```bash
aws ec2 stop-instances  --instance-ids "$(terraform output -raw instance_id)"
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
```

Stopped costs ~$2.50/mo for storage. All Jenkins state persists on the EBS volume and the Elastic IP
keeps the address stable. **Webhooks are silently discarded while stopped** — expected, not a fault.

## If Jenkins is not running after apply

`user_data` runs once and Terraform does not verify it. Check:

```bash
sudo tail -50 /var/log/cloud-init-output.log
sudo systemctl status jenkins docker
sudo bash /var/lib/cloud/instance/user-data.txt    # the script is idempotent; safe to re-run
```
````

- [ ] **Step 4: Commit**

```bash
git add terraform/jenkins/
git commit -m "terraform/jenkins: idempotent bootstrap and README

user_data runs once and Terraform does not verify it succeeded, so the
script is written to be safely re-runnable over SSH -- iterating that way
turns a 3-minute destroy/recreate loop into seconds."
git push origin master
```

---

### Task 5: CI guard helpers, test-first (G1, G2)

**Files:**
- Create: `scripts/ci/should-skip-build.sh`, `scripts/ci/images-exist.sh`, `scripts/tests/test-ci-guards.sh`

**Interfaces:**
- Produces:
  - `scripts/ci/should-skip-build.sh <commit-message>` → prints `skip` or `build`, exit 0.
  - `scripts/ci/images-exist.sh` → reads env `ECR_REPOS` (space-separated), `TAG`, `AWS_REGION`; optional `CI_STUB_DESCRIBE_CMD` for tests; prints `present` or `missing`, exit 0.
- Consumed by: `Jenkinsfile` (Task 6).

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test-ci-guards.sh`:

```bash
#!/usr/bin/env bash
# Tests the two pipeline decision helpers with NO AWS access. ECR lookups are stubbed via the
# CI_STUB_DESCRIBE_CMD env var the script honours -- same pattern as test-sync-values.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0

# ---- G2: the [skip ci] guard -------------------------------------------------------------------
got="$(scripts/ci/should-skip-build.sh 'ci: image tag abc1234 [skip ci]')"
[ "$got" = "skip" ] || fail "bot commit should skip, got '$got'"; pass=$((pass+1))

got="$(scripts/ci/should-skip-build.sh 'feat: add a league filter')"
[ "$got" = "build" ] || fail "normal commit should build, got '$got'"; pass=$((pass+1))

got="$(scripts/ci/should-skip-build.sh 'fix: mention [skip ci] in the docs')"
[ "$got" = "skip" ] || fail "substring anywhere must skip (fail safe), got '$got'"; pass=$((pass+1))

multiline="$(printf 'subject line\n\nbody mentioning [skip ci]\n')"
got="$(scripts/ci/should-skip-build.sh "$multiline")"
[ "$got" = "skip" ] || fail "multi-line message body should skip, got '$got'"; pass=$((pass+1))

got="$(scripts/ci/should-skip-build.sh '')"
[ "$got" = "build" ] || fail "empty message should build, got '$got'"; pass=$((pass+1))

# ---- G1: the already-built check ---------------------------------------------------------------
export AWS_REGION=il-central-1 TAG=abc1234 ECR_REPOS="voteball-backend voteball-worker"

export CI_STUB_DESCRIBE_CMD="true"      # every lookup succeeds
got="$(scripts/ci/images-exist.sh)"
[ "$got" = "present" ] || fail "all images found should be present, got '$got'"; pass=$((pass+1))

export CI_STUB_DESCRIBE_CMD="false"     # every lookup fails
got="$(scripts/ci/images-exist.sh)"
[ "$got" = "missing" ] || fail "no images found should be missing, got '$got'"; pass=$((pass+1))

# Partial: backend present, worker absent. Must be 'missing' -- a partial push must rebuild.
cat > /tmp/ci-stub-partial.sh <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "voteball-backend" ] && exit 0; done
exit 1
STUB
chmod +x /tmp/ci-stub-partial.sh
export CI_STUB_DESCRIBE_CMD=/tmp/ci-stub-partial.sh
got="$(scripts/ci/images-exist.sh)"
[ "$got" = "missing" ] || fail "partial push must rebuild, got '$got'"; pass=$((pass+1))

echo "PASS: $pass assertions"
```

```bash
chmod +x scripts/tests/test-ci-guards.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/tests/test-ci-guards.sh`
Expected: FAIL — `scripts/ci/should-skip-build.sh: No such file or directory`

- [ ] **Step 3: Write `scripts/ci/should-skip-build.sh`**

```bash
#!/usr/bin/env bash
# G2 -- Jenkins has NO native [skip ci] support; that is a GitHub Actions feature.
#
# Without this guard, the tag-bump commit the pipeline itself pushes fires the webhook, Jenkins
# builds that new SHA, pushes images, bumps the tag, commits again -- an unbounded build loop that
# consumes ECR storage and continuously rolls production pods.
#
# Prints "skip" or "build". Deliberately fails safe: any occurrence of the marker anywhere in the
# message skips, because a spurious skip costs one manual rebuild while a spurious build costs a loop.
set -euo pipefail

msg="${1-}"
if [ -z "$msg" ] && [ $# -eq 0 ]; then
  msg="$(git log -1 --pretty=%B)"
fi

case "$msg" in
  *"[skip ci]"*) echo "skip" ;;
  *)             echo "build" ;;
esac
```

```bash
chmod +x scripts/ci/should-skip-build.sh
```

- [ ] **Step 4: Write `scripts/ci/images-exist.sh`**

```bash
#!/usr/bin/env bash
# G1 -- terraform/ecr.tf sets image_tag_mutability = "IMMUTABLE", so pushing an existing tag is
# rejected. Because tags are the commit SHA, re-running a build (routine in Jenkins) would fail at
# the push step for no real reason.
#
# Prints "present" only if EVERY repository already holds this tag, else "missing".
#
# Fails safe in the opposite direction to should-skip-build.sh: any lookup failure yields "missing"
# and the pipeline rebuilds. A redundant build is harmless; a green build that shipped nothing is not.
set -euo pipefail

: "${ECR_REPOS:?ECR_REPOS must be set (space-separated repository names)}"
: "${TAG:?TAG must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"

# Tests override this to run offline; production uses the real CLI.
describe="${CI_STUB_DESCRIBE_CMD:-}"

for repo in $ECR_REPOS; do
  if [ -n "$describe" ]; then
    "$describe" "$repo" "$TAG" >/dev/null 2>&1 || { echo "missing"; exit 0; }
  else
    aws ecr describe-images \
      --repository-name "$repo" \
      --image-ids "imageTag=$TAG" \
      --region "$AWS_REGION" >/dev/null 2>&1 || { echo "missing"; exit 0; }
  fi
done

echo "present"
```

```bash
chmod +x scripts/ci/images-exist.sh
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/tests/test-ci-guards.sh`
Expected: `PASS: 8 assertions`

- [ ] **Step 6: Commit**

```bash
git add scripts/ci/ scripts/tests/test-ci-guards.sh
git commit -m "scripts/ci: testable guards for the [skip ci] loop and immutable tags

G2 is the highest-impact difference between GitHub Actions and Jenkins:
[skip ci] is a GitHub Actions feature Jenkins has never heard of, so the
pipeline's own tag-bump commit would retrigger it forever. G1 is the
immutable-tag rejection that makes every build re-run fail.

Both are extracted from the Jenkinsfile so they can be tested offline,
following the scripts/tests/test-sync-values.sh precedent -- pipeline
logic testable only by triggering real builds is what makes G2 dangerous."
git push origin master
```

---

### Task 6: The `Jenkinsfile` (§7)

**Files:**
- Create: `Jenkinsfile`

**Interfaces:**
- Consumes: `scripts/ci/should-skip-build.sh`, `scripts/ci/images-exist.sh` (Task 5).
- Requires Jenkins credential IDs `voteball-deploy-key` (SSH) and repo env from the job config.

- [ ] **Step 1: Create `Jenkinsfile`**

```groovy
// Voteball CI. Builds, scans and pushes the four images, then commits the new image tag to master.
// ArgoCD observes that commit and rolls the Deployments -- Jenkins never touches the cluster and
// holds no cluster credentials.
//
// Design: docs/design/2026-07-20-jenkins-migration-design.md  (G1-G7 referenced below)

pipeline {
  agent any

  options {
    // Two builds racing to rewrite values.yaml and push to master would conflict. Also bounds the
    // damage if the G2 guard ever fails.
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))   // G5
    timestamps()
  }

  parameters {
    // G3 -- a manually triggered build has an empty changeset and would otherwise skip everything.
    // G6 -- this checkbox does not appear until the job has run once; that first run is expected
    // to do nothing. See the runbook in docs/cicd.md.
    booleanParam(name: 'FORCE_BUILD', defaultValue: false,
                 description: 'Build even if this commit touches no files under services/')
  }

  triggers { githubPush() }

  environment {
    // AWS_REGION and CLUSTER_NAME are NOT set here. They are Jenkins global environment variables
    // (Manage Jenkins > System > Global properties), which is the direct equivalent of the GitHub
    // repo variables the retired pipeline used: identity stays out of the repository, so a fork
    // supplies its own. See CLAUDE.md -- a hardcoded region or prefix here would be a bug.
    // ECR_REGISTRY is derived at runtime in 'Resolve tag and account'; it cannot be built here
    // because the account ID is not known until then.
    TRIVY_IMAGE = 'aquasec/trivy:0.58.1'
    TRIVY_CACHE = '/var/lib/trivy-cache'
  }

  stages {

    // G2 -- Jenkins has no native [skip ci]. Without this, the pipeline's own tag-bump commit
    // retriggers it forever.
    stage('Guard: is this our own commit?') {
      steps {
        script {
          def msg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
          def verdict = sh(script: "scripts/ci/should-skip-build.sh '${msg.replace("'", "'\\''")}'",
                           returnStdout: true).trim()
          if (verdict == 'skip') {
            currentBuild.result = 'NOT_BUILT'
            currentBuild.description = 'Skipped: tag-bump commit ([skip ci])'
            error('SKIP_CI')   // caught below; aborts without running anything else
          }
        }
      }
    }

    stage('Resolve tag and account') {
      steps {
        script {
          // Fail loudly and early if the global properties are missing, rather than producing
          // image references like "null.dkr.ecr.null.amazonaws.com" that fail confusingly later.
          if (!env.AWS_REGION || !env.CLUSTER_NAME) {
            error('AWS_REGION and CLUSTER_NAME must be set as Jenkins global environment variables ' +
                  '(Manage Jenkins > System > Global properties). See docs/cicd.md.')
          }
          env.TAG = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text',
                                  returnStdout: true).trim()
          env.ECR_REGISTRY = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.ECR_REPOS = "${env.CLUSTER_NAME}-backend ${env.CLUSTER_NAME}-worker " +
                          "${env.CLUSTER_NAME}-nginx ${env.CLUSTER_NAME}-backup"
          echo "Building ${env.TAG} into ${env.ECR_REGISTRY}"
        }
      }
    }

    // G1 -- ECR tags are immutable, so re-pushing an existing SHA is rejected. If everything is
    // already there, skip straight to the tag bump instead of failing.
    stage('Already built?') {
      steps {
        script {
          env.ALREADY_BUILT = sh(script: 'scripts/ci/images-exist.sh', returnStdout: true).trim()
          if (env.ALREADY_BUILT == 'present') {
            echo "All images for ${env.TAG} are already in ECR -- skipping build, scan and push."
          }
        }
      }
    }

    stage('Build images') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }   // G3
      } }
      steps {
        sh '''
          set -eu
          aws ecr get-login-password --region "$AWS_REGION" \
            | docker login --username AWS --password-stdin "$ECR_REGISTRY"
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-backend:$TAG" services/backend
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-worker:$TAG"  services/worker
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-nginx:$TAG"   services/frontend
          docker build -t "$ECR_REGISTRY/$CLUSTER_NAME-backup:$TAG"  services/backup
        '''
      }
    }

    stage('Trivy scan') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        // The cache mount is load-bearing: without it the ~50MB vulnerability database is
        // re-downloaded on each of the four scans, every build, risking ghcr.io rate limits.
        sh '''
          set -eu
          for repo in backend worker nginx; do
            echo "--- trivy $CLUSTER_NAME-$repo (blocking) ---"
            docker run --rm \
              -v /var/run/docker.sock:/var/run/docker.sock \
              -v "$TRIVY_CACHE":/root/.cache/trivy \
              "$TRIVY_IMAGE" image --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed \
              "$ECR_REGISTRY/$CLUSTER_NAME-$repo:$TAG"
          done

          # The backup image is a third-party base (postgres:17-alpine + aws-cli) whose CVEs are
          # upstream Go-tooling issues outside this project's control: surface, do not block.
          echo "--- trivy $CLUSTER_NAME-backup (report only) ---"
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$TRIVY_CACHE":/root/.cache/trivy \
            "$TRIVY_IMAGE" image --severity CRITICAL,HIGH --exit-code 0 --ignore-unfixed \
            "$ECR_REGISTRY/$CLUSTER_NAME-backup:$TAG"
        '''
      }
    }

    stage('Push to ECR') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        sh '''
          set -eu
          for repo in backend worker nginx backup; do
            docker push "$ECR_REGISTRY/$CLUSTER_NAME-$repo:$TAG"
          done
        '''
      }
    }

    // ArgoCD watches charts/voteball on master. This commit IS the deploy.
    stage('Bump image tag') {
      when { anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } } }
      steps {
        sshagent(credentials: ['voteball-deploy-key']) {     // G4
          sh '''
            set -eu
            sed -i -E "s/^  tag: \\".*\\"/  tag: \\"$TAG\\"/" charts/voteball/values.yaml

            git config user.name  "jenkins"
            git config user.email "jenkins@voteball.local"
            git add charts/voteball/values.yaml

            if git diff --cached --quiet; then
              echo "values.yaml already names $TAG -- nothing to commit"
              exit 0
            fi

            # [skip ci] is written for continuity and documentation; the Guard stage is what
            # actually enforces it in Jenkins. Do not remove either.
            git commit -m "ci: image tag $TAG [skip ci]"

            # Same race scripts/deploy.sh hit (commits ed39db2, 1269ba8): origin/master may have
            # moved while this build ran.
            git pull --rebase --autostash origin master
            git push origin HEAD:master
          '''
        }
      }
    }
  }

  post {
    always {
      // G5 -- this host is persistent, unlike GitHub's runners.
      sh 'docker image prune -f || true'
    }
    failure {
      // G7 -- there is no email. This line is the record; check the UI.
      echo 'BUILD FAILED. No notification is sent (see docs/cicd.md, G7).'
    }
  }
}
```

- [ ] **Step 2: Verify the referenced scripts exist and are executable**

```bash
test -x scripts/ci/should-skip-build.sh && test -x scripts/ci/images-exist.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add Jenkinsfile
git commit -m "Add Jenkinsfile: build, scan, push, bump

Mirrors the retired GitHub Actions pipeline stage for stage. ArgoCD still
owns deployment; this pipeline's last act is a commit.

Each stage carries the G-number from the design doc it addresses, so the
non-obvious guards are self-documenting: the [skip ci] loop (G2), the
immutable-tag re-run (G1), the path filter and its manual override (G3),
the deploy key and rebase (G4), and image pruning on a persistent agent (G5)."
git push origin master
```

---

### Task 7: Apply the stack — **BILLED RESOURCES, STOP FOR CONFIRMATION**

**Files:** none (infrastructure only)

- [ ] **Step 1: Confirm with the human before proceeding**

State plainly: this creates a `t3.medium` instance and an Elastic IP, about **$30/month** while running. Do not run `apply` without an explicit go-ahead.

- [ ] **Step 2: Generate the key pair**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/voteball-jenkins -C voteball-jenkins -N ''
```
Expected: creates `~/.ssh/voteball-jenkins` and `~/.ssh/voteball-jenkins.pub`.

- [ ] **Step 3: Write the tfvars**

```bash
cd terraform/jenkins
cp jenkins.tfvars.example jenkins.tfvars
printf 'admin_cidr      = "%s/32"\npublic_key_path = "~/.ssh/voteball-jenkins.pub"\n' \
  "$(curl -s https://checkip.amazonaws.com)" >> jenkins.tfvars
```

- [ ] **Step 4: Confirm it is gitignored**

```bash
git check-ignore -v terraform/jenkins/jenkins.tfvars
```
Expected: a line naming `.gitignore` — **if this prints nothing, stop and fix Task 1.**

- [ ] **Step 5: Plan, showing full output**

```bash
cd terraform/jenkins && terraform init && terraform plan -var-file=jenkins.tfvars
```
Expected: `Plan: 7 to add, 0 to change, 0 to destroy.` — `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_instance_profile`, `aws_key_pair`, `aws_security_group`, `aws_instance`, `aws_eip`. Review the security group's ingress CIDRs before continuing.

- [ ] **Step 6: Apply, streaming output**

```bash
cd terraform/jenkins && terraform apply -var-file=jenkins.tfvars
```
Never pipe to `tail` — it masks the exit code and can report a failed run as success.

- [ ] **Step 7: Verify the bootstrap actually completed**

`terraform apply` succeeds even if `user_data` failed. Check explicitly:

```bash
ssh -i ~/.ssh/voteball-jenkins ec2-user@"$(terraform output -raw jenkins_public_ip)" \
  'sudo grep -c "BOOTSTRAP COMPLETE" /var/log/cloud-init-output.log; systemctl is-active jenkins docker'
```
Expected: `1`, then `active`, `active`.

If not: `sudo tail -50 /var/log/cloud-init-output.log`, fix `user_data.sh`, and re-run it in place (`sudo bash /var/lib/cloud/instance/user-data.txt`) — it is idempotent. Do a clean destroy/recreate only once at the end to prove it works from scratch.

- [ ] **Step 8: Verify the UI is reachable ONLY through the tunnel**

```bash
curl -m 5 -sS "http://$(terraform output -raw jenkins_public_ip):8080/" && echo "REACHABLE" || echo "BLOCKED (expected)"
```
Expected: `BLOCKED (expected)` — your IP is not in GitHub's ranges.

Then, in a second terminal:
```bash
eval "$(cd terraform/jenkins && terraform output -raw ssh_tunnel_command)"
```
and browse `http://localhost:8080`. Expected: the Jenkins unlock screen.

- [ ] **Step 9: Verify the instance profile grants ECR and nothing else**

```bash
ssh -i ~/.ssh/voteball-jenkins ec2-user@"$(terraform output -raw jenkins_public_ip)" \
  'aws ecr get-login-password --region il-central-1 >/dev/null && echo "ECR OK"; \
   aws eks list-clusters --region il-central-1 2>&1 | head -1'
```
Expected: `ECR OK`, then an `AccessDeniedException` for EKS. **A success on the EKS call means the policy is too broad — stop and fix `iam.tf`.**

---

### Task 8: First-time Jenkins configuration (§6) and the runbook

**Files:**
- Modify: `docs/cicd.md` (runbook section only; the full rewrite is Task 12)

- [ ] **Step 1: Unlock and install plugins**

Through the tunnel at `http://localhost:8080`:

```bash
ssh -i ~/.ssh/voteball-jenkins ec2-user@<ip> 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
```

Choose **Select plugins to install** and install exactly: **Git, Pipeline, GitHub, Credentials Binding, Docker Pipeline, SSH Agent**. Create the admin user.

Then set the two global environment variables — **Manage Jenkins → System → Global properties → Environment variables**:

| Name | Value |
|---|---|
| `AWS_REGION` | `il-central-1` |
| `CLUSTER_NAME` | `voteball` |

These are the direct equivalent of the GitHub repo variables the retired pipeline used, and they exist for the same reason: identity must not be hardcoded in the repository, so a fork supplies its own (`CLAUDE.md`). The `Jenkinsfile` fails fast with a clear message if either is missing.

- [ ] **Step 2: Create the deploy key (G4)**

```bash
ssh-keygen -t ed25519 -f /tmp/voteball-deploy-key -C jenkins-deploy -N ''
cat /tmp/voteball-deploy-key.pub
```

In GitHub → repo **Settings → Deploy keys → Add deploy key**: paste the public half, tick **Allow write access**.

In Jenkins → **Manage Jenkins → Credentials → System → Global → Add**: kind *SSH Username with private key*, **ID `voteball-deploy-key`** (the `Jenkinsfile` references this exact ID), username `git`, paste the private half.

```bash
shred -u /tmp/voteball-deploy-key /tmp/voteball-deploy-key.pub
```

- [ ] **Step 3: Create the job**

**New Item → Pipeline** named `voteball`. Configure:
- **Pipeline → Definition:** *Pipeline script from SCM*
- **SCM:** Git, URL `git@github.com:Latnook/voteball.git`, credential `voteball-deploy-key`
- **Branch:** `*/master`
- **Script Path:** `Jenkinsfile`
- **Build Triggers:** tick *GitHub hook trigger for GITScm polling* — leave the GitHub webhook itself **uncreated** until Task 10.

- [ ] **Step 4: The G6 first run**

Click **Build Now**. The `FORCE_BUILD` checkbox does **not** exist yet — this run registers it. Expect the build to check out, resolve the tag, and skip the build stages (no changeset).

Expected: build completes; `FORCE_BUILD` now appears under *Build with Parameters*.

- [ ] **Step 5: First real build**

**Build with Parameters → FORCE_BUILD ✓ → Build.**

Expected: four images built, Trivy passes on three and reports on `backup`, four pushes succeed, `values.yaml` bumped and pushed to `master`.

Verify from your machine:
```bash
git pull --rebase origin master && git log --oneline -1
aws ecr describe-images --repository-name voteball-backend --region il-central-1 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output text
```
Expected: a `ci: image tag <sha> [skip ci]` commit, and that SHA in ECR.

- [ ] **Step 6: Record the runbook**

Add a `## First-time Jenkins setup` section to `docs/cicd.md` capturing steps 1–5 as a numbered list, including the exact plugin list, the credential ID `voteball-deploy-key`, and an explicit note that **`FORCE_BUILD` is absent until the job has run once (G6)**.

- [ ] **Step 7: Commit**

```bash
git add docs/cicd.md
git commit -m "docs/cicd.md: first-time Jenkins setup runbook

Records the manual configuration this pass performs through the UI. The
plugin list is fixed here rather than left to the setup wizard's
'recommended' set because it is also the input to the deferred JCasC pass."
git push origin master
```

---

### Task 9: Disarm GitHub Actions (§10 step 3) — **ORDERING IS MANDATORY**

Both pipelines must never be trigger-driven at once: a single push would start both, and both would race to bump `values.yaml`.

**Files:**
- Modify: `.github/workflows/ci.yml:2-8`

- [ ] **Step 1: Replace the trigger**

```yaml
name: build-scan-push-deploy
# DISARMED 2026-07-20: superseded by Jenkins (see docs/design/2026-07-20-jenkins-migration-design.md).
# Kept temporarily, manual-only, so a single `git revert` restores a working pipeline while the
# Jenkins migration is verified. Deleted in a follow-up commit once verification passes.
on:
  workflow_dispatch:
```

- [ ] **Step 2: Verify no push trigger remains**

```bash
grep -A3 '^on:' .github/workflows/ci.yml
```
Expected: only `workflow_dispatch:` — no `push:`, no `branches:`.

- [ ] **Step 3: Commit and confirm it took effect**

```bash
git add .github/workflows/ci.yml
git commit -m "ci.yml: disarm the GitHub Actions trigger ahead of the Jenkins cutover

Manual-only from here. GitHub Actions must be disarmed BEFORE the Jenkins
webhook is enabled: with both armed, one push starts both pipelines and
they race to bump values.yaml -- the collision this migration exists to
avoid. Kept (not deleted) so rollback stays one revert away until
verification passes."
git push origin master
```

Then check the repo's **Actions** tab: this push must produce **no new run**.

---

### Task 10: Enable the webhook (§10 step 4)

- [ ] **Step 1: Generate the shared secret**

```bash
openssl rand -hex 32
```

In Jenkins → **Manage Jenkins → System → GitHub → Advanced → Shared secrets → Add**: kind *Secret text*, paste the value.

- [ ] **Step 2: Create the webhook**

GitHub → repo **Settings → Webhooks → Add webhook**:
- **Payload URL:** output of `terraform output -raw webhook_url` (trailing slash required)
- **Content type:** `application/json`
- **Secret:** the value from step 1
- **Events:** *Just the push event*

- [ ] **Step 3: Verify delivery**

In the webhook's **Recent Deliveries** tab, check the ping. Expected: HTTP `200`.

If it times out, the instance is stopped, or GitHub's ranges changed — re-run `terraform apply` to refresh `local.github_hook_cidrs`.

- [ ] **Step 4: Verify an end-to-end trigger**

```bash
printf '\n<!-- webhook trigger test -->\n' >> services/frontend/index.html
git add services/frontend/index.html
git commit -m "test: verify Jenkins webhook triggers a build"
git push origin master
```

Expected: a Jenkins build starts within seconds, builds all four images, and pushes a tag bump.

---

### Task 11: Verify, then delete the GitHub Actions path (§10 steps 5–6)

The verification list from the design's §Verification. **Do not proceed to the deletions until every item passes.**

- [ ] **Step 1: Prove G2 — the loop guard**

This is the highest-impact check: it is the only failure that runs unattended and accrues cost.

Find the `ci: image tag ... [skip ci]` commit Jenkins pushed in Task 10, then confirm Jenkins did **not** start a build for it:

```bash
git log --oneline -3
```
Expected in Jenkins: **no build** for the bump commit, or a build marked `NOT_BUILT` with description `Skipped: tag-bump commit ([skip ci])`. Any *successful full build* of the bump commit means the guard is broken — **stop and fix before continuing.**

- [ ] **Step 2: Prove G1 — idempotent re-runs**

Re-run the last successful build (**Build with Parameters → FORCE_BUILD ✓**) against the same commit.

Expected: **green**, with `All images for <sha> are already in ECR -- skipping build, scan and push.` in the log, and no `ImageAlreadyExists` error.

- [ ] **Step 3: Prove the path filter (G3)**

```bash
printf '\n' >> docs/cicd.md && git commit -am "docs: whitespace, should not trigger a build" && git push origin master
```
Expected: either no build, or a build whose build/scan/push stages are skipped. `values.yaml` unchanged.

- [ ] **Step 4: Prove ArgoCD still deploys**

```bash
kubectl get application voteball -n argocd -o jsonpath='{.status.sync.status}{"\n"}'
kubectl get pods -n devops-app
```
Expected: `Synced`, all pods `Running`, zero `ImagePullBackOff`.

- [ ] **Step 5: Prove stop/start preserves state**

```bash
cd terraform/jenkins
aws ec2 stop-instances  --instance-ids "$(terraform output -raw instance_id)"
# wait for stopped, then:
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
```
Expected: after boot, the same Elastic IP, the `voteball` job present, and build history intact.

- [ ] **Step 6: Delete `ci.yml`**

```bash
git rm .github/workflows/ci.yml
git commit -m "Remove the GitHub Actions pipeline

Superseded by Jenkins, verified end to end: the [skip ci] loop guard (G2)
and the immutable-tag re-run path (G1) both confirmed against real builds.
Recoverable from git history."
git push origin master
```

- [ ] **Step 7: Delete the OIDC federation — LAST, as its own commit**

Until this point, rollback was one revert. After it, recovering GitHub Actions also requires re-applying the main stack and re-adding four repo variables.

```bash
git rm terraform/github-oidc.tf
```

Remove the `github_actions_role_arn` output block at `terraform/outputs.tf:56-58`.

```bash
cd terraform && terraform fmt -recursive && terraform validate
```
Expected: `Success! The configuration is valid.`

> The role and OIDC provider still exist in AWS until the next `terraform apply` of the main stack. That is expected — they are removed on the next rebuild cycle.

```bash
git add terraform/
git commit -m "Remove the GitHub Actions OIDC federation

The Jenkins host authenticates via an EC2 instance profile, so the
federated role and its OIDC provider are dead weight.

Deleted last and separately, after verification: until this commit,
restoring GitHub Actions was a single revert. NOTE: terraform/eks.tf and
terraform/irsa.tf also mention an OIDC provider -- that is the CLUSTER's,
which underpins every IRSA role. It is unrelated and untouched."
git push origin master
```

- [ ] **Step 8: Confirm nothing stale remains**

```bash
git grep -in "github actions\|github_actions\|AWS_ROLE_ARN" -- ':!docs/design/*' ':!docs/superpowers/*'
```
Expected: no hits outside the historical design/plan documents. Any hit in `README*`, `CLAUDE.md` or `docs/` (other than design docs) is Task 12's work.

---

### Task 12: Documentation, including two graded deliverables (§9)

**Files:**
- Rewrite: `docs/cicd.md`
- Modify: `docs/eks/architecture.md:43,71`, `README.submission.md:46`, `CLAUDE.md`, `README.md`, `docs/security.md`, `docs/maintenance.md`, `docs/production-readiness.md`

- [ ] **Step 1: Rewrite `docs/cicd.md`**

Keep the existing structure. Changes:
- The pipeline diagram becomes `git push → webhook → Jenkins (EC2) → ECR → values.yaml bump → ArgoCD → pods`.
- Delete **Required GitHub repo variables** entirely (obsolete).
- Replace §2 "Authenticate to AWS — OIDC" with the instance-profile model.
- Keep the **first-time setup runbook** from Task 8.
- Add instance start/stop commands.
- Rewrite the **failure modes** table for G1–G7:

| Symptom | Cause | Fix |
|---|---|---|
| Build loop: every build triggers another | G2 guard removed or bypassed | Restore the Guard stage; check `should-skip-build.sh` |
| `ImageAlreadyExists` on push | G1 check bypassed; ECR tags are immutable | Restore the *Already built?* stage |
| `FORCE_BUILD` missing from the UI | G6 — parameters register only after the first run | Run the job once with no parameters |
| Build fails, nobody notices | G7 — no notifications are configured | Check the Jenkins UI; accepted limitation |
| Webhook delivery times out | Instance stopped, or GitHub's CIDRs changed | Start the instance; re-run `terraform apply` |
| `docker push` fails, repository not found | Main stack destroyed; `ecr.tf` sets `force_delete = true` | Expected while torn down; deploy first |
| Disk full | G5 prune removed | Restore `docker image prune` in `post` |

- Re-record the **verified run** table against the real Jenkins run.

- [ ] **Step 2: Update the architecture diagram — GRADED DELIVERABLE**

`docs/eks/architecture.md:43`, change:
```
    gh[GitHub Actions<br/>OIDC → build/Trivy/ECR] --> ecr
```
to:
```
    jenkins[Jenkins on EC2<br/>instance profile → build/Trivy/ECR] --> ecr
```
and update the prose at line 71 to match.

Verify the Mermaid still parses by viewing the rendered file.

- [ ] **Step 3: Update `README.submission.md` — GRADED DELIVERABLE**

Line 46 currently describes the GitHub Actions flow. Replace with the Jenkins flow, and add the green-build evidence (job page and a successful run) — the assessor reads this file, not `docs/cicd.md`.

- [ ] **Step 4: Update `CLAUDE.md`**

In **Deployment → CI/CD**, replace the GitHub Actions paragraph. Add a standing warning in the same spirit as the existing `final_snapshot_identifier` one:

> **Do not remove the `Guard` stage from the `Jenkinsfile` or `scripts/ci/should-skip-build.sh`.**
> Jenkins has no native `[skip ci]`; without that guard the pipeline's own tag-bump commit
> retriggers it, producing an unbounded, billable build loop that continuously rolls pods.
> See G2 in `docs/design/2026-07-20-jenkins-migration-design.md`.

Also note that `terraform/jenkins/` is a separate stack with its own state, deliberately outside `destroy.sh`'s scope.

- [ ] **Step 5: Update `docs/security.md`**

Add: the instance-profile model replacing OIDC federation (§3); the inbound/outbound posture and its two accepted positions — unrestricted egress and the plain-HTTP webhook authenticated by shared secret (§4); and the `docker`-group root-equivalence on the build host (§6).

- [ ] **Step 6: Update the remaining files**

- `README.md` — any CI/CD mention.
- `docs/maintenance.md` — add Jenkins core/plugin updates and the pinned `aquasec/trivy:0.58.1` bump alongside the EKS support-window tracking.
- `docs/production-readiness.md` — replace the GitHub Actions reference; note that the Jenkins host is single-instance with no backup (accepted), and that JCasC and SSM access remain deferred.
- The two 2026-07-20 design docs — a one-line forward reference only. **Do not rewrite them; they are historical records.**

- [ ] **Step 7: Verify and commit**

```bash
git grep -in "github actions\|AWS_ROLE_ARN" -- ':!docs/design/*' ':!docs/superpowers/*'
```
Expected: no hits.

```bash
git add -A
git commit -m "docs: retarget CI/CD documentation from GitHub Actions to Jenkins

Rewrites docs/cicd.md around the instance-profile model and the G1-G7
failure modes, and updates the two graded deliverables: the Mermaid
architecture diagram (which still named GitHub Actions) and
README.submission.md.

Adds a standing CLAUDE.md warning against removing the [skip ci] guard --
Jenkins has no native support for it, so its removal reintroduces an
unbounded billable build loop."
git push origin master
```

---

## Deferred (explicitly out of scope)

- **JCasC** — `jenkins.yaml` + `plugins.txt` so the host self-configures. The plugin list fixed in Task 8 is its input.
- **SSM Session Manager** as the UI access path, closing port 22 entirely.
- **Build failure notifications** (G7) — accepted as absent.

## Self-review

**Spec coverage.** §1→T2/T3; §2→T1; §3→T2; §4→T3; §5→T3/T7; §6→T4/T8; §7→T5/T6; §8→Deferred; §9→T12; §10→T9/T10/T11. G1→T5/T6/T11.2; G2→T5/T6/T11.1; G3→T6/T11.3; G4→T6/T8.2; G5→T6; G6→T6/T8.4; G7→T6/T12. Verification 1–11 → T7.7–7.9, T10.4, T11.1–11.5, T12.

**Type consistency.** `should-skip-build.sh` prints `skip`/`build`; `images-exist.sh` prints `present`/`missing`; both spellings are used identically in the tests (T5) and the `Jenkinsfile` (T6). Credential ID `voteball-deploy-key` matches between T6's `sshagent` and T8's setup. `ECR_REPOS`, `TAG`, `AWS_REGION`, `CI_STUB_DESCRIBE_CMD` agree across T5 and T6.

**Known gap accepted:** the `Jenkinsfile` itself is only verifiable by running real builds; T11 is the test cycle for it, which is why T5 extracted the two decision helpers into separately-testable scripts.
