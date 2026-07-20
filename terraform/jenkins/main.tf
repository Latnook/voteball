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

  # This rule exposes the ENTIRE Jenkins UI -- not just a webhook endpoint -- to GitHub's published
  # hook CIDR ranges over plaintext HTTP. That residual risk is accepted because those ranges are
  # narrow and GitHub-owned (refreshed at apply time, see the data.http.github_meta comment above),
  # and because the endpoint additionally requires a webhook shared secret configured in both GitHub
  # and the Jenkins job -- so reachability alone does not grant access. The maintainer's own UI access
  # never uses this rule; it goes through the SSH tunnel below, whose traffic arrives from localhost
  # and is never evaluated against this security group.
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
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  # sort() makes the choice of subnet deterministic. data.aws_subnets.default.ids is returned in
  # whatever order AWS feels like, and a reorder between applies would otherwise change subnet_id
  # and force a replacement -- which, now that the root volume survives termination (below) but the
  # instance itself does not, would mean a working Jenkins host on one subnet getting destroyed and
  # recreated on another for no operator-visible reason.
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
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
    # Jenkins' job configuration, credentials (including voteball-deploy-key, used to push to
    # master) and build history live ONLY on this root volume. Default delete_on_termination=true
    # would destroy all of it the moment the instance is terminated. If this stack is ever torn
    # down for good, the volume must be deleted manually -- it will NOT go away on its own.
    delete_on_termination = false
  }

  # user_data executes only on first boot. Editing user_data.sh later would never take effect on
  # the already-running instance anyway -- Terraform's default behavior of treating a user_data
  # change as replacement-triggering would only destroy Jenkins' state (credentials, jobs, build
  # history) to re-run a script whose output is already present. ignore_changes here is therefore
  # correct, not a workaround. Deliberately rebuilding the host from scratch is a manual
  # `terraform taint` / `terraform apply -replace`, which is the intended workflow for that case.
  lifecycle {
    ignore_changes = [user_data]
  }

  tags = { Name = "${var.cluster_name}-jenkins" }
}

# So the address survives the stop/start cycles that keep this host at ~$2.50/mo when idle.
resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"
  tags     = { Name = "${var.cluster_name}-jenkins" }
}
