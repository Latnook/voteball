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
