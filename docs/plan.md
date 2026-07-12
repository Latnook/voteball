# Voteball Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Voteball — a public poll correlating football fandom with Israeli political-party voting — as a brand-new, fully self-contained repository, deployed on a single-EC2 k3s cluster reachable at `voteball.latnook.com`.

**Architecture:** Three containers (frontend/nginx, backend/Flask, worker/Python) on one k3s node, provisioned by a standalone Terraform stack and deployed by a standalone Ansible playbook — both bootstrapped as one-time copies of proven patterns from the `Rolling AWS Project files` repo (S3App), then developed independently with zero ongoing coupling. Postgres stores static seed data (leagues/clubs), synced party lists, raw votes, and worker-computed rollup tables the backend reads for fast results.

**Tech Stack:** Terraform (`hashicorp/aws ~> 6.0`), Ansible, Docker, k3s (Docker-backed, Traefik disabled), Helm 3, Python 3.12 / Flask 3.1 / psycopg2-binary / pydantic 2.x (matching S3App's stack), plain HTML/CSS/vanilla JS (no frontend build step), pytest for backend/worker unit tests.

## Global Constraints

- Region `il-central-1`; EC2 in AZ `il-central-1c`; RDS in AZ `il-central-1b` (verified real pricing: `t3.small` $0.024/hr, `db.t4g.micro` PostgreSQL Single-AZ $0.018/hr).
- Resource name prefix: `voteball`. Subdomain: `voteball.latnook.com` (existing `latnook.com` Route 53 hosted zone).
- New repo at `/home/latnook/Documents/Voteball/`, public on GitHub, name `voteball`.
- Single environment for now — no dev/prod split, no `single_instance` toggle (Voteball is single-EC2-only, unlike S3App; the multi-instance conditional logic in S3App's modules is deliberately not carried over — YAGNI).
- All containers run as non-root (`uid 1000` for backend/worker Python images, matching S3App's Task 1 precedent); frontend nginx keeps the same `CHOWN`/`SETUID`/`SETGID` capability exception S3App's frontend needed.
- Postgres connections use `sslmode=require` (`DB_SSLMODE` env var, matching S3App's backend).
- Knesset OData API verified live during design: `GET https://knesset.gov.il/Odata/ParliamentInfo.svc/KNS_Faction?$format=json&$filter=IsCurrent%20eq%20true` returns JSON `{"value": [{"FactionID": int, "Name": str, "KnessetNum": int, "StartDate": str, "FinishDate": str|null, "IsCurrent": bool, "LastUpdatedDate": str}, ...]}`. A stray legacy row (`FactionID=911`, `KnessetNum=1`, `Name="אין נתונים"`) also has `IsCurrent=true` — filtered out by keeping only rows whose `KnessetNum` equals the max `KnessetNum` present in the response.
- Admin endpoints authenticate via a static shared secret in the `X-Admin-Secret` header, compared against env var `ADMIN_SECRET`.

---

## Task 1: Bootstrap the `voteball` repository

**Files:**
- Create: `/home/latnook/Documents/Voteball/.gitignore`
- Create: `/home/latnook/Documents/Voteball/README.md`
- Create (copied starting point): `/home/latnook/Documents/Voteball/ansible-project/roles/common/tasks/main.yml`
- Create (copied starting point): `/home/latnook/Documents/Voteball/ansible-project/roles/k3s/tasks/main.yml`, `defaults/main.yml`, `handlers/main.yml`
- Create (copied starting point): `/home/latnook/Documents/Voteball/ansible-project/roles/app-compose/tasks/certbot.yml` (kept under the same relative path the k3s role's `include_tasks` expects, `{{ role_path }}/../app-compose/tasks/certbot.yml`)

**Interfaces:**
- Produces: the repo root that every later task writes into. No code interfaces yet.

- [ ] **Step 1: Create the directory and initialize git**

```bash
mkdir -p "/home/latnook/Documents/Voteball"
cd "/home/latnook/Documents/Voteball"
git init
```

- [ ] **Step 2: Write `.gitignore`**

```
# SSH private keys
*.pem

# Terraform secrets and generated state
terraform/voteball.tfvars
terraform/terraform.tfstate
terraform/terraform.tfstate.backup
terraform/.terraform/

# Ansible secrets and generated inventory
ansible-project/inventories/voteball/group_vars/all/secrets.yml
ansible-project/inventories/voteball/hosts
ansible-project/inventories/voteball/group_vars/all/main.yml

# Python
__pycache__/
*.pyc
.pytest_cache/
```

- [ ] **Step 3: Write `README.md`**

```markdown
# Voteball

A public poll correlating football fandom with Israeli political-party voting,
timed to the runup to the next Knesset election. Deployed on a single-EC2 k3s
cluster at https://voteball.latnook.com.

Bootstrapped from infra patterns proven in the `Rolling AWS Project files`
(S3App) repo — see that repo's `docs/superpowers/specs/2026-07-11-voteball-design.md`
for the full design rationale. From this initial commit onward, this repo is
fully independent: no shared code, no shared Terraform state, no shared
Ansible roles.

See `docs/plan.md` (copied from the design repo's implementation plan) for
the build sequence.
```

- [ ] **Step 4: Copy the starting-point Ansible files**

```bash
S3APP="/home/latnook/Documents/Rolling AWS Project files"
VOTEBALL="/home/latnook/Documents/Voteball"

mkdir -p "$VOTEBALL/ansible-project/roles/common/tasks"
cp "$S3APP/ansible-project/roles/common/tasks/main.yml" \
   "$VOTEBALL/ansible-project/roles/common/tasks/main.yml"

mkdir -p "$VOTEBALL/ansible-project/roles/k3s/tasks" \
         "$VOTEBALL/ansible-project/roles/k3s/defaults" \
         "$VOTEBALL/ansible-project/roles/k3s/handlers"
cp "$S3APP/ansible-project/roles/k3s/tasks/main.yml" \
   "$VOTEBALL/ansible-project/roles/k3s/tasks/main.yml"
cp "$S3APP/ansible-project/roles/k3s/defaults/main.yml" \
   "$VOTEBALL/ansible-project/roles/k3s/defaults/main.yml"
cp "$S3APP/ansible-project/roles/k3s/handlers/main.yml" \
   "$VOTEBALL/ansible-project/roles/k3s/handlers/main.yml"

mkdir -p "$VOTEBALL/ansible-project/roles/app-compose/tasks"
cp "$S3APP/ansible-project/roles/app-compose/tasks/certbot.yml" \
   "$VOTEBALL/ansible-project/roles/app-compose/tasks/certbot.yml"
```

These are edited in Task 19 (k3s role: image names, app directory, ConfigMap/Secret keys, Helm release name) and Task 20 (playbook/inventory). Left untouched here — this step is purely the starting-point copy.

- [ ] **Step 5: Create the GitHub remote and push**

```bash
cd "/home/latnook/Documents/Voteball"
gh repo create voteball --public --source=. --remote=origin
git add .gitignore README.md ansible-project
git commit -m "Bootstrap voteball repo: copy starting-point common/k3s roles and certbot task from S3App"
git push -u origin master
```

- [ ] **Step 6: Verify**

```bash
gh repo view voteball --web=false
git -C "/home/latnook/Documents/Voteball" log --oneline -1
```
Expected: repo shows on GitHub as public, one commit locally matching the pushed `HEAD`.

---

## Task 2: Terraform infrastructure (networking, compute, database, iam, notifications)

**Files:**
- Create: `terraform/versions.tf`, `terraform/providers.tf`, `terraform/variables.tf`, `terraform/main.tf`, `terraform/dns.tf`, `terraform/outputs.tf`, `terraform/voteball.tfvars.example`
- Create: `terraform/modules/networking/{main,variables,outputs}.tf`
- Create: `terraform/modules/compute/{main,variables,outputs}.tf`
- Create: `terraform/modules/database/{main,variables,outputs}.tf`
- Create: `terraform/modules/iam/{main,variables,outputs}.tf`
- Create: `terraform/modules/notifications/{main,variables,outputs}.tf`

**Interfaces:**
- Produces: `terraform output frontend_public_ip`, `rds_endpoint`, `sns_topic_arn` (consumed by Task 3's inventory generation and Task 20's Ansible variables).

These modules are written fresh, informed by S3App's proven resource shapes (read during design at `terraform/modules/{networking,compute,database,iam,notifications}/main.tf` in the `Rolling AWS Project files` repo) but simplified: S3App's `single_instance` conditional (3-EC2 vs. 1-EC2 mode) is dropped entirely since Voteball is single-EC2-only, permanently.

- [ ] **Step 1: `versions.tf` and `providers.tf`**

`terraform/versions.tf`:
```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

`terraform/providers.tf`:
```hcl
provider "aws" {
  region = var.aws_region
}
```

- [ ] **Step 2: `variables.tf`**

```hcl
variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "il-central-1"
}

variable "instance_type" {
  description = "EC2 instance type for the app server"
  type        = string
  default     = "t3.small"
}

variable "ami_id" {
  description = "AMI ID for the app instance (Amazon Linux 2023, il-central-1)"
  type        = string
  default     = "ami-03eff74cb4f6a6272"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed SSH access to the instance"
  type        = string
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance"
  type        = string
  sensitive   = true
}

variable "notification_email" {
  description = "Email address for SNS milestone notifications"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = "Voteball-EC2-pem"
}
```

- [ ] **Step 3: networking module**

`terraform/modules/networking/main.tf`:
```hcl
locals {
  name_prefix = "voteball"
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app"
  description = "HTTP/HTTPS/SSH for the single-instance k3s deployment"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Voteball = "app"
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "PostgreSQL from the app instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Voteball = "rds"
  }
}
```

`terraform/modules/networking/variables.tf`:
```hcl
variable "ssh_allowed_cidr" {
  type = string
}
```

`terraform/modules/networking/outputs.tf`:
```hcl
output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "sg_app_id" {
  value = aws_security_group.app.id
}

output "sg_rds_id" {
  value = aws_security_group.rds.id
}
```

- [ ] **Step 4: compute module**

`terraform/modules/compute/main.tf`:
```hcl
locals {
  name_prefix = "voteball"
}

resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name     = "${local.name_prefix}-app"
    Voteball = "app"
  }
}

resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_app_id]
  iam_instance_profile   = var.instance_profile

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  tags = {
    Name     = "${local.name_prefix}-app"
    Voteball = "app"
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
```

`terraform/modules/compute/variables.tf`:
```hcl
variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "key_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "sg_app_id" {
  type = string
}

variable "instance_profile" {
  type = string
}
```

`terraform/modules/compute/outputs.tf`:
```hcl
output "public_ip" {
  value = aws_eip.app.public_ip
}
```

- [ ] **Step 5: database module**

`terraform/modules/database/main.tf`:
```hcl
locals {
  name_prefix = "voteball"
}

data "aws_db_subnet_group" "default" {
  name = "default-${var.vpc_id}"
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = "17.9"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp2"
  storage_encrypted     = true

  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = data.aws_db_subnet_group.default.name
  vpc_security_group_ids = [var.sg_rds_id]
  availability_zone      = "il-central-1b"
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  backup_window           = "04:53-05:23"
  maintenance_window      = "tue:05:32-tue:06:02"

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  deletion_protection        = false

  # Low-stakes, time-boxed poll data — no final-snapshot ceremony needed.
  skip_final_snapshot = true

  lifecycle {
    ignore_changes = [password]
  }

  tags = {
    Voteball = "rds"
  }
}
```

`terraform/modules/database/variables.tf`:
```hcl
variable "vpc_id" {
  type = string
}

variable "sg_rds_id" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}
```

`terraform/modules/database/outputs.tf`:
```hcl
output "endpoint" {
  value = aws_db_instance.main.endpoint
}
```

- [ ] **Step 6: iam module (trimmed — no S3 permissions)**

`terraform/modules/iam/main.tf`:
```hcl
locals {
  name_prefix = "voteball"
}

resource "aws_iam_policy" "app" {
  name = "${local.name_prefix}-app-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.notifications_topic_arn
      },
      # certbot's dns-route53 plugin (DNS-01 renewal) — same pattern as
      # S3App's iam module. ListHostedZones/GetChange have no resource-level
      # permissions in IAM and must stay "*"; only the actual record change
      # is zone-scoped.
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = var.hosted_zone_arn
      }
    ]
  })

  tags = {
    Voteball = "iam"
  }
}

resource "aws_iam_role" "app" {
  name        = "${local.name_prefix}-app-role"
  description = "Allows the Voteball EC2 instance to call AWS services on your behalf."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Voteball = "iam"
  }
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app.arn
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name_prefix}-app-role"
  role = aws_iam_role.app.name
}
```

`terraform/modules/iam/variables.tf`:
```hcl
variable "notifications_topic_arn" {
  type = string
}

variable "hosted_zone_arn" {
  type = string
}
```

`terraform/modules/iam/outputs.tf`:
```hcl
output "instance_profile_name" {
  value = aws_iam_instance_profile.app.name
}
```

- [ ] **Step 7: notifications module**

`terraform/modules/notifications/main.tf`:
```hcl
locals {
  name_prefix = "voteball"
}

resource "aws_sns_topic" "notifications" {
  name = "${local.name_prefix}-notifications"

  tags = {
    Voteball = "sns"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn                       = aws_sns_topic.notifications.arn
  protocol                        = "email"
  endpoint                        = var.notification_email
  confirmation_timeout_in_minutes = 1
  endpoint_auto_confirms          = false
}
```

`terraform/modules/notifications/variables.tf`:
```hcl
variable "notification_email" {
  type = string
}
```

`terraform/modules/notifications/outputs.tf`:
```hcl
output "topic_arn" {
  value = aws_sns_topic.notifications.arn
}
```

- [ ] **Step 8: root `main.tf`, `dns.tf`, `outputs.tf`**

`terraform/main.tf`:
```hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "compute_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availabilityZone"
    values = ["il-central-1c"]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_route53_zone" "primary" {
  name = "latnook.com"
}

resource "aws_key_pair" "voteball" {
  key_name   = var.key_name
  public_key = file("${path.module}/../Voteball-EC2-pem.pub")
}

module "networking" {
  source           = "./modules/networking"
  ssh_allowed_cidr = var.ssh_allowed_cidr
}

module "notifications" {
  source              = "./modules/notifications"
  notification_email  = var.notification_email
}

module "iam" {
  source                   = "./modules/iam"
  notifications_topic_arn  = module.notifications.topic_arn
  hosted_zone_arn          = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.primary.zone_id}"
}

module "database" {
  source      = "./modules/database"
  vpc_id      = module.networking.vpc_id
  sg_rds_id   = module.networking.sg_rds_id
  db_password = var.db_password
}

module "compute" {
  source           = "./modules/compute"
  ami_id           = var.ami_id
  instance_type    = var.instance_type
  key_name         = aws_key_pair.voteball.key_name
  subnet_id        = data.aws_subnet.compute_az.id
  sg_app_id        = module.networking.sg_app_id
  instance_profile = module.iam.instance_profile_name
}
```

`terraform/dns.tf`:
```hcl
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "voteball.latnook.com"
  type    = "A"
  ttl     = 300
  records = [module.compute.public_ip]
}
```

`terraform/outputs.tf`:
```hcl
output "app_public_ip" {
  value = module.compute.public_ip
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "sns_topic_arn" {
  value = module.notifications.topic_arn
}
```

- [ ] **Step 9: `voteball.tfvars.example`**

```hcl
ssh_allowed_cidr   = "YOUR_IP/32"
db_password        = "changeme"
notification_email = "8847444@proton.me"
```

- [ ] **Step 10: Generate the dedicated EC2 key pair**

```bash
cd "/home/latnook/Documents/Voteball"
ssh-keygen -t ed25519 -f Voteball-EC2-pem -N "" -C "voteball-ec2"
mv Voteball-EC2-pem Voteball-EC2-pem.pem
chmod 400 Voteball-EC2-pem.pem
```
This produces `Voteball-EC2-pem.pub` (referenced by `aws_key_pair.voteball` above, committed — public keys aren't secret) and `Voteball-EC2-pem.pem` (gitignored by the `*.pem` rule from Task 1).

- [ ] **Step 11: `terraform init` and `terraform validate`**

```bash
cd "/home/latnook/Documents/Voteball/terraform"
cp voteball.tfvars.example voteball.tfvars
# edit voteball.tfvars: set real ssh_allowed_cidr (curl -s https://checkip.amazonaws.com), db_password
terraform init
terraform validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 12: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add terraform Voteball-EC2-pem.pub
git commit -m "Add Terraform infra: networking, compute, database, iam, notifications"
git push
```

---

## Task 3: Apply infrastructure and generate the Ansible inventory

**Files:**
- Create: `scripts/generate-inventory.sh`
- Create (generated, gitignored): `ansible-project/inventories/voteball/hosts`, `ansible-project/inventories/voteball/group_vars/all/main.yml`

**Interfaces:**
- Consumes: Task 2's Terraform outputs (`app_public_ip`, `rds_endpoint`, `sns_topic_arn`).
- Produces: `ansible-project/inventories/voteball/hosts` with an `[app]` group (consumed by Task 20's `site-k3s.yml`).

- [ ] **Step 1: Write `scripts/generate-inventory.sh`**

```bash
#!/usr/bin/env bash
# Usage: ./scripts/generate-inventory.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
INV_DIR="$SCRIPT_DIR/../ansible-project/inventories/voteball"

cd "$TF_DIR"

APP_IP=$(terraform output -raw app_public_ip)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
SNS_TOPIC=$(terraform output -raw sns_topic_arn)

mkdir -p "$INV_DIR/group_vars/all"

cat > "$INV_DIR/hosts" <<EOF
[app]
voteball-app ansible_host=${APP_IP}

[all:vars]
ansible_user=ec2-user
EOF

cat > "$INV_DIR/group_vars/all/main.yml" <<EOF
# Generated by scripts/generate-inventory.sh — do not edit by hand.
aws_region: il-central-1

db_host: ${RDS_ENDPOINT}
db_name: postgres
db_user: postgres

sns_topic: ${SNS_TOPIC}

frontend_domain: voteball.latnook.com
EOF

echo "Inventory written to $INV_DIR"
echo "Next: set db_pass and admin_secret in inventories/voteball/group_vars/all/secrets.yml"
```

```bash
chmod +x "/home/latnook/Documents/Voteball/scripts/generate-inventory.sh"
```

- [ ] **Step 2: Apply the infrastructure**

Confirm with the user before running — this creates real, billed AWS resources.

```bash
cd "/home/latnook/Documents/Voteball/terraform"
terraform plan
# review the plan, then:
terraform apply
```

- [ ] **Step 3: Generate the inventory**

```bash
cd "/home/latnook/Documents/Voteball"
./scripts/generate-inventory.sh
```
Expected: `ansible-project/inventories/voteball/hosts` and `group_vars/all/main.yml` written, showing the real EC2 public IP and RDS endpoint.

- [ ] **Step 4: Commit the script (not the generated inventory — gitignored)**

```bash
git add scripts/generate-inventory.sh
git commit -m "Add generate-inventory.sh"
git push
```

---

## Task 4: Database schema and seed data

**Files:**
- Create: `ansible-project/roles/backend/files/backend/schema.sql`
- Create: `ansible-project/roles/backend/files/backend/seed.sql`

**Interfaces:**
- Produces: 7 tables (`leagues`, `clubs`, `previous_parties`, `upcoming_parties`, `votes`, `vote_upcoming_parties`, `alert_state`) plus `rollup_previous`/`rollup_upcoming`, consumed by Task 5's `db.py` (`init_db()`), Tasks 6–10's query functions, and Task 12's worker rollup recomputation.

- [ ] **Step 1: Write `schema.sql`**

```sql
CREATE TABLE IF NOT EXISTS leagues (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS clubs (
    id SERIAL PRIMARY KEY,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    name TEXT NOT NULL,
    UNIQUE (league_id, name)
);

CREATE TABLE IF NOT EXISTS previous_parties (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    knesset_faction_id TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS upcoming_parties (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    club_id INTEGER REFERENCES clubs(id),
    previous_vote_status TEXT NOT NULL CHECK (previous_vote_status IN ('voted', 'did_not_vote')),
    previous_party_id INTEGER REFERENCES previous_parties(id),
    upcoming_vote_status TEXT NOT NULL CHECK (upcoming_vote_status IN ('considering', 'undecided')),
    cookie_token TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS vote_upcoming_parties (
    vote_id INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id) ON DELETE CASCADE,
    PRIMARY KEY (vote_id, upcoming_party_id)
);

CREATE TABLE IF NOT EXISTS alert_state (
    id INTEGER PRIMARY KEY DEFAULT 1,
    last_seen_total INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT single_row CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS rollup_previous (
    league_id INTEGER NOT NULL,
    club_id INTEGER,
    previous_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_league_club ON rollup_previous (league_id, club_id);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_party ON rollup_previous (previous_party_id);

CREATE TABLE IF NOT EXISTS rollup_upcoming (
    league_id INTEGER NOT NULL,
    club_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_upcoming_league_club ON rollup_upcoming (league_id, club_id);
CREATE INDEX IF NOT EXISTS idx_rollup_upcoming_party ON rollup_upcoming (upcoming_party_id);
```

- [ ] **Step 2: Write `seed.sql`**

```sql
INSERT INTO alert_state (id, last_seen_total) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;

INSERT INTO leagues (name) VALUES
    ('World Cup 2026'), ('UCL'), ('EPL'), ('La Liga'), ('Serie A'), ('Bundesliga'), ('Israeli Premier League')
ON CONFLICT (name) DO NOTHING;

INSERT INTO clubs (league_id, name)
SELECT l.id, c.name FROM leagues l
JOIN (VALUES
    ('World Cup 2026', 'Brazil'), ('World Cup 2026', 'Argentina'), ('World Cup 2026', 'France'),
    ('World Cup 2026', 'England'), ('World Cup 2026', 'Spain'), ('World Cup 2026', 'Germany'),
    ('World Cup 2026', 'Portugal'), ('World Cup 2026', 'Netherlands'), ('World Cup 2026', 'Italy'),
    ('World Cup 2026', 'Belgium'), ('World Cup 2026', 'Croatia'), ('World Cup 2026', 'Uruguay'),
    ('World Cup 2026', 'Colombia'), ('World Cup 2026', 'Mexico'), ('World Cup 2026', 'USA'),
    ('World Cup 2026', 'Canada'), ('World Cup 2026', 'Japan'), ('World Cup 2026', 'South Korea'),
    ('World Cup 2026', 'Morocco'), ('World Cup 2026', 'Senegal'), ('World Cup 2026', 'Nigeria'),
    ('World Cup 2026', 'Ghana'), ('World Cup 2026', 'Egypt'), ('World Cup 2026', 'Tunisia'),
    ('World Cup 2026', 'Algeria'), ('World Cup 2026', 'Ivory Coast'), ('World Cup 2026', 'Cameroon'),
    ('World Cup 2026', 'Australia'), ('World Cup 2026', 'Iran'), ('World Cup 2026', 'Saudi Arabia'),
    ('World Cup 2026', 'Qatar'), ('World Cup 2026', 'Ecuador'), ('World Cup 2026', 'Chile'),
    ('World Cup 2026', 'Peru'), ('World Cup 2026', 'Poland'), ('World Cup 2026', 'Switzerland'),
    ('World Cup 2026', 'Denmark'), ('World Cup 2026', 'Sweden'), ('World Cup 2026', 'Serbia'),
    ('World Cup 2026', 'Israel'),

    ('UCL', 'Real Madrid'), ('UCL', 'Manchester City'), ('UCL', 'Bayern Munich'),
    ('UCL', 'Barcelona'), ('UCL', 'Liverpool'), ('UCL', 'Paris Saint-Germain'),
    ('UCL', 'Inter Milan'), ('UCL', 'Juventus'), ('UCL', 'Manchester United'),
    ('UCL', 'Chelsea'), ('UCL', 'Arsenal'), ('UCL', 'AC Milan'),
    ('UCL', 'Atletico Madrid'), ('UCL', 'Borussia Dortmund'), ('UCL', 'Napoli'),
    ('UCL', 'Porto'), ('UCL', 'Benfica'), ('UCL', 'Ajax'),

    ('EPL', 'Arsenal'), ('EPL', 'Aston Villa'), ('EPL', 'Bournemouth'),
    ('EPL', 'Brentford'), ('EPL', 'Brighton & Hove Albion'), ('EPL', 'Chelsea'),
    ('EPL', 'Crystal Palace'), ('EPL', 'Everton'), ('EPL', 'Fulham'),
    ('EPL', 'Ipswich Town'), ('EPL', 'Leicester City'), ('EPL', 'Liverpool'),
    ('EPL', 'Manchester City'), ('EPL', 'Manchester United'), ('EPL', 'Newcastle United'),
    ('EPL', 'Nottingham Forest'), ('EPL', 'Southampton'), ('EPL', 'Tottenham Hotspur'),
    ('EPL', 'West Ham United'), ('EPL', 'Wolverhampton Wanderers'),

    ('La Liga', 'Real Madrid'), ('La Liga', 'Barcelona'), ('La Liga', 'Atletico Madrid'),
    ('La Liga', 'Athletic Bilbao'), ('La Liga', 'Real Sociedad'), ('La Liga', 'Real Betis'),
    ('La Liga', 'Villarreal'), ('La Liga', 'Valencia'), ('La Liga', 'Sevilla'),
    ('La Liga', 'Girona'), ('La Liga', 'Osasuna'), ('La Liga', 'Celta Vigo'),
    ('La Liga', 'Rayo Vallecano'), ('La Liga', 'Getafe'), ('La Liga', 'Las Palmas'),
    ('La Liga', 'Alaves'), ('La Liga', 'Espanyol'), ('La Liga', 'Leganes'),
    ('La Liga', 'Mallorca'), ('La Liga', 'Valladolid'),

    ('Serie A', 'Inter Milan'), ('Serie A', 'AC Milan'), ('Serie A', 'Juventus'),
    ('Serie A', 'Napoli'), ('Serie A', 'Roma'), ('Serie A', 'Lazio'),
    ('Serie A', 'Atalanta'), ('Serie A', 'Fiorentina'), ('Serie A', 'Bologna'),
    ('Serie A', 'Torino'), ('Serie A', 'Udinese'), ('Serie A', 'Genoa'),
    ('Serie A', 'Cagliari'), ('Serie A', 'Verona'), ('Serie A', 'Lecce'),
    ('Serie A', 'Parma'), ('Serie A', 'Como'), ('Serie A', 'Venezia'),
    ('Serie A', 'Empoli'), ('Serie A', 'Monza'),

    ('Bundesliga', 'Bayern Munich'), ('Bundesliga', 'Borussia Dortmund'), ('Bundesliga', 'RB Leipzig'),
    ('Bundesliga', 'Bayer Leverkusen'), ('Bundesliga', 'Eintracht Frankfurt'), ('Bundesliga', 'VfB Stuttgart'),
    ('Bundesliga', 'Borussia Monchengladbach'), ('Bundesliga', 'SC Freiburg'), ('Bundesliga', 'Werder Bremen'),
    ('Bundesliga', 'Union Berlin'), ('Bundesliga', 'Mainz 05'), ('Bundesliga', 'Wolfsburg'),
    ('Bundesliga', 'Hoffenheim'), ('Bundesliga', 'FC Augsburg'), ('Bundesliga', 'VfL Bochum'),
    ('Bundesliga', 'FC Heidenheim'), ('Bundesliga', 'Holstein Kiel'), ('Bundesliga', 'St. Pauli'),

    ('Israeli Premier League', 'Maccabi Haifa'), ('Israeli Premier League', 'Maccabi Tel Aviv'),
    ('Israeli Premier League', 'Hapoel Beer Sheva'), ('Israeli Premier League', 'Hapoel Tel Aviv'),
    ('Israeli Premier League', 'Beitar Jerusalem'), ('Israeli Premier League', 'Maccabi Netanya'),
    ('Israeli Premier League', 'Hapoel Haifa'), ('Israeli Premier League', 'Bnei Sakhnin'),
    ('Israeli Premier League', 'Ashdod'), ('Israeli Premier League', 'Hapoel Jerusalem'),
    ('Israeli Premier League', 'Kiryat Shmona'), ('Israeli Premier League', 'Maccabi Bnei Reineh'),
    ('Israeli Premier League', 'Hapoel Petah Tikva'), ('Israeli Premier League', 'Hapoel Kfar Saba')
) AS c(league_name, name) ON l.name = c.league_name
ON CONFLICT (league_id, name) DO NOTHING;
```

This is a starting curated list, not a live-synced one — the World Cup 2026 roster in particular may drift slightly from the final 48-team qualification. It's editable the same way `upcoming_parties` is (direct SQL), just infrequently, since club/league fandom doesn't change during the campaign the way party lists do.

- [ ] **Step 3: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
mkdir -p ansible-project/roles/backend/files/backend
git add ansible-project/roles/backend/files/backend/schema.sql ansible-project/roles/backend/files/backend/seed.sql
git commit -m "Add database schema and seed data (leagues, clubs, alert_state)"
git push
```

---

## Task 5: Backend skeleton — Flask app, DB module, `/health`

**Files:**
- Create: `ansible-project/roles/backend/files/backend/db.py`
- Create: `ansible-project/roles/backend/files/backend/app.py`
- Create: `ansible-project/roles/backend/files/backend/requirements.txt`
- Test: `ansible-project/roles/backend/files/backend/tests/conftest.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_app.py`

**Interfaces:**
- Produces: `db.get_db() -> psycopg2.connection`, `db.init_db(conn)` (runs `schema.sql` then `seed.sql`), a Flask `app` object with `/health`. Tasks 6–10 add routes to this same `app.py` and import `db.get_db`.
- Test prerequisite: a local Postgres reachable at `localhost:5432` for running the test suite —
  `docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17`

- [ ] **Step 1: `requirements.txt`**

```
flask==3.1.3
pydantic==2.12.5
boto3==1.42.85
psycopg2-binary==2.9.11
pytest==8.3.4
requests==2.32.3
```

- [ ] **Step 2: Write `db.py`**

```python
import os
import psycopg2

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ.get('DB_NAME', 'postgres')
DB_USER = os.environ.get('DB_USER', 'postgres')
DB_PASS = os.environ['DB_PASS']
DB_SSLMODE = os.environ.get('DB_SSLMODE', 'require')


def get_db():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS,
        sslmode=DB_SSLMODE
    )


def init_db(conn):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(base_dir, 'schema.sql')) as f:
        schema_sql = f.read()
    with open(os.path.join(base_dir, 'seed.sql')) as f:
        seed_sql = f.read()

    cur = conn.cursor()
    cur.execute(schema_sql)
    cur.execute(seed_sql)
    conn.commit()
    cur.close()
```

- [ ] **Step 3: Write the failing test**

`tests/conftest.py`:
```python
import os
import sys
import pytest
import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('DB_HOST', 'localhost')
os.environ.setdefault('DB_NAME', 'postgres')
os.environ.setdefault('DB_USER', 'postgres')
os.environ.setdefault('DB_PASS', 'test')
os.environ.setdefault('DB_SSLMODE', 'disable')
os.environ.setdefault('SNS_TOPIC', 'arn:aws:sns:il-central-1:000000000000:test')
os.environ.setdefault('AWS_REGION', 'il-central-1')
os.environ.setdefault('ADMIN_SECRET', 'test-admin-secret')

import db as db_module


@pytest.fixture
def conn():
    connection = db_module.get_db()
    cur = connection.cursor()
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, votes, rollup_previous,
            rollup_upcoming, clubs, leagues, previous_parties, upcoming_parties,
            alert_state CASCADE
    ''')
    connection.commit()
    cur.close()
    db_module.init_db(connection)
    yield connection
    connection.close()


@pytest.fixture
def client(conn):
    import app as app_module
    app_module.app.config['TESTING'] = True
    with app_module.app.test_client() as c:
        yield c
```

`tests/test_app.py`:
```python
def test_health(client):
    resp = client.get('/health')
    assert resp.status_code == 200
    assert resp.get_json() == {'status': 'ok'}
```

- [ ] **Step 4: Run test to verify it fails**

```bash
cd "/home/latnook/Documents/Voteball/ansible-project/roles/backend/files/backend"
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
sleep 3
python -m pytest tests/test_app.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'app'` (or connection works but `/health` doesn't exist yet).

- [ ] **Step 5: Write `app.py`**

```python
from flask import Flask, jsonify
import db

app = Flask(__name__)


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


if __name__ == '__main__':
    conn = db.get_db()
    db.init_db(conn)
    conn.close()
    app.run(host='0.0.0.0', port=5000)
```

- [ ] **Step 6: Run test to verify it passes**

```bash
python -m pytest tests/test_app.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/db.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/requirements.txt \
        ansible-project/roles/backend/files/backend/tests/
git commit -m "Backend: Flask skeleton, DB module, /health, TDD scaffolding"
git push
```

---

## Task 6: `GET /api/options`

**Files:**
- Create: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: `db.get_db()` from Task 5.
- Produces: `queries.get_options(conn) -> dict` with keys `leagues`, `clubs`, `previous_parties`, `upcoming_parties` — each a list of `{"id": int, "name": str}` (`clubs` items also carry `"league_id": int`). Consumed by Task 15's frontend voting form.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_queries.py
import queries


def test_get_options_returns_seeded_leagues(conn):
    options = queries.get_options(conn)
    league_names = {l['name'] for l in options['leagues']}
    assert 'EPL' in league_names
    assert 'Israeli Premier League' in league_names

    club_names = {c['name'] for c in options['clubs']}
    assert 'Liverpool' in club_names

    epl = next(l for l in options['leagues'] if l['name'] == 'EPL')
    epl_clubs = [c for c in options['clubs'] if c['league_id'] == epl['id']]
    assert len(epl_clubs) == 20

    assert options['previous_parties'] == []
    assert options['upcoming_parties'] == []
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'queries'`.

- [ ] **Step 3: Write `queries.py`**

```python
def get_options(conn):
    cur = conn.cursor()

    cur.execute('SELECT id, name FROM leagues ORDER BY name')
    leagues = [{'id': r[0], 'name': r[1]} for r in cur.fetchall()]

    cur.execute('SELECT id, league_id, name FROM clubs ORDER BY name')
    clubs = [{'id': r[0], 'league_id': r[1], 'name': r[2]} for r in cur.fetchall()]

    cur.execute('SELECT id, name FROM previous_parties ORDER BY name')
    previous_parties = [{'id': r[0], 'name': r[1]} for r in cur.fetchall()]

    cur.execute('SELECT id, name FROM upcoming_parties ORDER BY name')
    upcoming_parties = [{'id': r[0], 'name': r[1]} for r in cur.fetchall()]

    cur.close()
    return {
        'leagues': leagues,
        'clubs': clubs,
        'previous_parties': previous_parties,
        'upcoming_parties': upcoming_parties,
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: PASS.

- [ ] **Step 5: Wire the route into `app.py`**

Add to `app.py` (after the `health` route):
```python
import queries


@app.route('/api/options', methods=['GET'])
def options():
    conn = db.get_db()
    result = queries.get_options(conn)
    conn.close()
    return jsonify(result)
```

- [ ] **Step 6: Test the route end-to-end**

```python
# add to tests/test_app.py
def test_options_endpoint(client):
    resp = client.get('/api/options')
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'leagues' in body
    assert any(l['name'] == 'EPL' for l in body['leagues'])
```
```bash
python -m pytest tests/test_app.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/
git commit -m "Backend: GET /api/options"
git push
```

---

## Task 7: `POST /api/vote`

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py`, `tests/test_app.py`

**Interfaces:**
- Consumes: `queries.get_options` output shape for valid IDs (test fixtures reuse seeded leagues/clubs).
- Produces: `queries.insert_vote(conn, league_id, club_id, previous_vote_status, previous_party_id, upcoming_vote_status, upcoming_party_ids, cookie_token) -> int` (returns the new vote id, raises `ValueError` on a duplicate `cookie_token`). `POST /api/vote` sets a `voteball_token` cookie (1-year `max_age`, `httponly`, `samesite=Lax`) on first vote and rejects (`409`) a second vote from the same cookie.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_queries.py
import pytest


def _epl_and_liverpool(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.close()
    return league_id, club_id


def test_insert_vote_league_only_did_not_vote_undecided(conn):
    import queries
    league_id, _ = _epl_and_liverpool(conn)

    vote_id = queries.insert_vote(
        conn,
        league_id=league_id, club_id=None,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='token-a',
    )
    assert vote_id > 0

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM vote_upcoming_parties WHERE vote_id = %s', (vote_id,))
    assert cur.fetchone()[0] == 0
    cur.close()


def test_insert_vote_with_club_and_multiple_upcoming_parties(conn):
    import queries
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Test Faction') RETURNING id")
    previous_party_id = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party B') RETURNING id")
    party_b = cur.fetchone()[0]
    conn.commit()
    cur.close()

    vote_id = queries.insert_vote(
        conn,
        league_id=league_id, club_id=club_id,
        previous_vote_status='voted', previous_party_id=previous_party_id,
        upcoming_vote_status='considering', upcoming_party_ids=[party_a, party_b],
        cookie_token='token-b',
    )

    cur = conn.cursor()
    cur.execute('SELECT upcoming_party_id FROM vote_upcoming_parties WHERE vote_id = %s ORDER BY upcoming_party_id', (vote_id,))
    assert [r[0] for r in cur.fetchall()] == sorted([party_a, party_b])
    cur.close()


def test_insert_vote_duplicate_cookie_token_rejected(conn):
    import queries
    league_id, _ = _epl_and_liverpool(conn)

    queries.insert_vote(
        conn, league_id=league_id, club_id=None,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='dup-token',
    )
    with pytest.raises(ValueError):
        queries.insert_vote(
            conn, league_id=league_id, club_id=None,
            previous_vote_status='did_not_vote', previous_party_id=None,
            upcoming_vote_status='undecided', upcoming_party_ids=[],
            cookie_token='dup-token',
        )
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: FAIL — `AttributeError: module 'queries' has no attribute 'insert_vote'`.

- [ ] **Step 3: Add `insert_vote` to `queries.py`**

```python
import psycopg2


def insert_vote(conn, league_id, club_id, previous_vote_status, previous_party_id,
                 upcoming_vote_status, upcoming_party_ids, cookie_token):
    cur = conn.cursor()
    try:
        cur.execute(
            '''INSERT INTO votes
               (league_id, club_id, previous_vote_status, previous_party_id,
                upcoming_vote_status, cookie_token)
               VALUES (%s, %s, %s, %s, %s, %s) RETURNING id''',
            (league_id, club_id, previous_vote_status, previous_party_id,
             upcoming_vote_status, cookie_token)
        )
        vote_id = cur.fetchone()[0]

        for party_id in upcoming_party_ids:
            cur.execute(
                'INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)',
                (vote_id, party_id)
            )

        conn.commit()
        return vote_id
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        raise ValueError(f'duplicate cookie_token: {cookie_token}')
    finally:
        cur.close()
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: PASS (3 new tests).

- [ ] **Step 5: Wire `POST /api/vote` into `app.py`**

```python
import uuid
from flask import request, make_response


@app.route('/api/vote', methods=['POST'])
def vote():
    token = request.cookies.get('voteball_token')
    is_new_token = token is None
    if is_new_token:
        token = uuid.uuid4().hex

    body = request.get_json(force=True, silent=True) or {}
    conn = db.get_db()
    try:
        vote_id = queries.insert_vote(
            conn,
            league_id=body.get('league_id'),
            club_id=body.get('club_id'),
            previous_vote_status=body.get('previous_vote_status'),
            previous_party_id=body.get('previous_party_id'),
            upcoming_vote_status=body.get('upcoming_vote_status'),
            upcoming_party_ids=body.get('upcoming_party_ids', []),
            cookie_token=token,
        )
    except ValueError:
        conn.close()
        return jsonify({'error': 'You have already voted'}), 409
    conn.close()

    resp = make_response(jsonify({'vote_id': vote_id}), 201)
    if is_new_token:
        resp.set_cookie('voteball_token', token, max_age=31536000, httponly=True, samesite='Lax')
    return resp
```

- [ ] **Step 6: Test the route end-to-end**

```python
# add to tests/test_app.py
def test_vote_endpoint_sets_cookie_and_rejects_duplicate(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201
    assert 'voteball_token' in resp.headers.get('Set-Cookie', '')

    resp2 = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp2.status_code == 409
```
```bash
python -m pytest tests/test_app.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/
git commit -m "Backend: POST /api/vote with cookie-based dedup"
git push
```

---

## Task 8: `GET /api/results`

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py`, `tests/test_app.py`

**Interfaces:**
- Consumes: `rollup_previous`/`rollup_upcoming` tables (populated by Task 12's worker in production; tests insert rows directly, matching how a fully-recomputed rollup would look).
- Produces: `queries.get_results_by_club(conn, club_id) -> dict`, `queries.get_results_by_league(conn, league_id) -> dict`, `queries.get_results_by_party(conn, party_type, party_id) -> dict` (`party_type` is `'previous'` or `'upcoming'`). Each returns `{"previous": [{"party_id": int|None, "party_name": str, "count": int}], "upcoming": [...]}` (the by-party queries return `{"breakdown": [{"league_id": int, "club_id": int|None, "count": int}]}` instead, since the club/league dimension has no separate name lookup requirement at the query layer — names are resolved by the frontend from `/api/options`). Consumed by Task 16's results dashboard.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_queries.py
def _seed_rollup_rows(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]

    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, party_x, 7)
    )
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, %s, NULL, %s)',
        (league_id, club_id, 3)
    )
    conn.commit()
    cur.close()
    return league_id, club_id, party_x


def test_get_results_by_club_includes_did_not_vote(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    result = queries.get_results_by_club(conn, club_id)
    previous = {row['party_id']: row['count'] for row in result['previous']}
    assert previous[party_x] == 7
    assert previous[None] == 3


def test_get_results_by_party_previous(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    result = queries.get_results_by_party(conn, 'previous', party_x)
    assert result['breakdown'] == [{'league_id': league_id, 'club_id': club_id, 'count': 7}]
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: FAIL — `AttributeError: module 'queries' has no attribute 'get_results_by_club'`.

- [ ] **Step 3: Add results queries to `queries.py`**

```python
def get_results_by_club(conn, club_id):
    return _results_for_filter(conn, 'club_id = %s', (club_id,))


def get_results_by_league(conn, league_id):
    return _results_for_filter(conn, 'league_id = %s', (league_id,))


def _results_for_filter(conn, where_clause, params):
    cur = conn.cursor()
    cur.execute(
        f'SELECT previous_party_id, SUM(vote_count) FROM rollup_previous '
        f'WHERE {where_clause} GROUP BY previous_party_id',
        params
    )
    previous = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.execute(
        f'SELECT upcoming_party_id, SUM(vote_count) FROM rollup_upcoming '
        f'WHERE {where_clause} GROUP BY upcoming_party_id',
        params
    )
    upcoming = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.close()
    return {'previous': previous, 'upcoming': upcoming}


def get_results_by_party(conn, party_type, party_id):
    table = 'rollup_previous' if party_type == 'previous' else 'rollup_upcoming'
    column = 'previous_party_id' if party_type == 'previous' else 'upcoming_party_id'

    cur = conn.cursor()
    cur.execute(
        f'SELECT league_id, club_id, SUM(vote_count) FROM {table} '
        f'WHERE {column} = %s GROUP BY league_id, club_id',
        (party_id,)
    )
    breakdown = [{'league_id': r[0], 'club_id': r[1], 'count': r[2]} for r in cur.fetchall()]
    cur.close()
    return {'breakdown': breakdown}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: PASS.

- [ ] **Step 5: Wire `GET /api/results` into `app.py`**

```python
@app.route('/api/results', methods=['GET'])
def results():
    by = request.args.get('by')
    conn = db.get_db()

    if by == 'club':
        club_id = request.args.get('id', type=int)
        result = queries.get_results_by_club(conn, club_id)
    elif by == 'league':
        league_id = request.args.get('id', type=int)
        result = queries.get_results_by_league(conn, league_id)
    elif by == 'party':
        party_type = request.args.get('type')
        party_id = request.args.get('id', type=int)
        if party_type not in ('previous', 'upcoming'):
            conn.close()
            return jsonify({'error': "type must be 'previous' or 'upcoming'"}), 400
        result = queries.get_results_by_party(conn, party_type, party_id)
    else:
        conn.close()
        return jsonify({'error': "by must be 'club', 'league', or 'party'"}), 400

    conn.close()
    return jsonify(result)
```

- [ ] **Step 6: Test the route end-to-end**

```python
# add to tests/test_app.py
def test_results_by_club_endpoint(client, conn):
    import queries
    cur = conn.cursor()
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.close()

    resp = client.get(f'/api/results?by=club&id={club_id}')
    assert resp.status_code == 200
    assert resp.get_json() == {'previous': [], 'upcoming': []}
```
```bash
python -m pytest tests/test_app.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/
git commit -m "Backend: GET /api/results (by club, league, and party)"
git push
```

---

## Task 9: Admin auth and Knesset OData sync

> **Superseded (2026-07-12):** the Knesset OData sync described in this task (`knesset_sync.py`,
> `POST /api/admin/sync-previous-parties`, `queries.upsert_previous_parties`, the
> `knesset_faction_id` column) was removed. `previous_parties` is now a plain admin-managed table
> (create/rename/delete, mirroring `upcoming_parties`), seeded manually. See
> `docs/superpowers/specs/2026-07-12-party-display-names-design.md` and
> `docs/superpowers/plans/2026-07-12-party-display-names.md` for the change. The admin-auth
> (`require_admin`) parts of this task are still accurate and current.

**Files:**
- Create: `ansible-project/roles/backend/files/backend/knesset_sync.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_knesset_sync.py`, `tests/test_app.py`

**Interfaces:**
- Produces: `knesset_sync.parse_current_factions(odata_json: dict) -> list[dict]` (pure function, `[{"knesset_faction_id": str, "name": str}, ...]`), `knesset_sync.fetch_current_factions() -> list[dict]` (HTTP call + parse), `queries.upsert_previous_parties(conn, factions: list[dict]) -> int` (returns count upserted). `POST /api/admin/sync-previous-parties` requires `X-Admin-Secret` header matching env `ADMIN_SECRET`.

- [ ] **Step 1: Write the failing test for the pure parsing function**

```python
# tests/test_knesset_sync.py
import knesset_sync

LIVE_SHAPED_RESPONSE = {
    "odata.metadata": "https://knesset.gov.il/Odata/ParliamentInfo.svc/$metadata#KNS_Faction",
    "value": [
        {"FactionID": 911, "Name": "אין נתונים", "KnessetNum": 1,
         "StartDate": "1900-01-01T00:00:00", "FinishDate": None,
         "IsCurrent": True, "LastUpdatedDate": "2019-01-24T11:45:06.46"},
        {"FactionID": 1096, "Name": "הליכוד ", "KnessetNum": 25,
         "StartDate": "2022-11-15T00:00:00", "FinishDate": None,
         "IsCurrent": True, "LastUpdatedDate": "2024-10-07T12:14:59.083"},
        {"FactionID": 1101, "Name": "יהדות התורה", "KnessetNum": 25,
         "StartDate": "2022-11-15T00:00:00", "FinishDate": None,
         "IsCurrent": True, "LastUpdatedDate": "2024-10-07T12:22:42.103"},
    ],
}


def test_parse_current_factions_drops_legacy_placeholder_and_strips_names():
    factions = knesset_sync.parse_current_factions(LIVE_SHAPED_RESPONSE)
    assert len(factions) == 2
    names = {f['name'] for f in factions}
    assert 'הליכוד' in names  # trailing space stripped
    assert 'אין נתונים' not in names
    ids = {f['knesset_faction_id'] for f in factions}
    assert ids == {'1096', '1101'}


def test_parse_current_factions_empty_response():
    assert knesset_sync.parse_current_factions({'value': []}) == []
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python -m pytest tests/test_knesset_sync.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'knesset_sync'`.

- [ ] **Step 3: Write `knesset_sync.py`**

```python
import requests

KNESSET_FACTION_URL = (
    'https://knesset.gov.il/Odata/ParliamentInfo.svc/KNS_Faction'
    '?$format=json&$filter=IsCurrent%20eq%20true'
)


def parse_current_factions(odata_json):
    rows = odata_json.get('value', [])
    if not rows:
        return []

    max_knesset_num = max(row['KnessetNum'] for row in rows)
    return [
        {'knesset_faction_id': str(row['FactionID']), 'name': row['Name'].strip()}
        for row in rows
        if row['KnessetNum'] == max_knesset_num
    ]


def fetch_current_factions():
    resp = requests.get(KNESSET_FACTION_URL, timeout=15)
    resp.raise_for_status()
    return parse_current_factions(resp.json())
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python -m pytest tests/test_knesset_sync.py -v
```
Expected: PASS.

- [ ] **Step 5: Add `upsert_previous_parties` to `queries.py`**

```python
def upsert_previous_parties(conn, factions):
    cur = conn.cursor()
    count = 0
    for faction in factions:
        cur.execute(
            '''INSERT INTO previous_parties (name, knesset_faction_id, updated_at)
               VALUES (%s, %s, NOW())
               ON CONFLICT (name) DO UPDATE SET
                   knesset_faction_id = EXCLUDED.knesset_faction_id,
                   updated_at = NOW()''',
            (faction['name'], faction['knesset_faction_id'])
        )
        count += 1
    conn.commit()
    cur.close()
    return count
```

- [ ] **Step 6: Write the failing test for the upsert**

```python
# add to tests/test_queries.py
def test_upsert_previous_parties_inserts_and_updates(conn):
    import queries
    n = queries.upsert_previous_parties(conn, [
        {'knesset_faction_id': '1096', 'name': 'Likud'},
        {'knesset_faction_id': '1101', 'name': 'Torah Judaism'},
    ])
    assert n == 2

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 2
    cur.close()

    # Re-sync with an updated faction id for the same name — should update, not duplicate
    queries.upsert_previous_parties(conn, [
        {'knesset_faction_id': '9999', 'name': 'Likud'},
    ])
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 2
    cur.execute("SELECT knesset_faction_id FROM previous_parties WHERE name = 'Likud'")
    assert cur.fetchone()[0] == '9999'
    cur.close()
```
```bash
python -m pytest tests/test_queries.py -v
```
Expected: PASS.

- [ ] **Step 7: Wire admin auth + the sync route into `app.py`**

```python
import os
from functools import wraps

ADMIN_SECRET = os.environ['ADMIN_SECRET']


def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if request.headers.get('X-Admin-Secret') != ADMIN_SECRET:
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return wrapper


import knesset_sync


@app.route('/api/admin/sync-previous-parties', methods=['POST'])
@require_admin
def sync_previous_parties():
    factions = knesset_sync.fetch_current_factions()
    conn = db.get_db()
    count = queries.upsert_previous_parties(conn, factions)
    conn.close()
    return jsonify({'synced': count})
```

- [ ] **Step 8: Test the route end-to-end (mocking the HTTP call, not the DB)**

```python
# add to tests/test_app.py
def test_sync_previous_parties_requires_admin_secret(client):
    resp = client.post('/api/admin/sync-previous-parties')
    assert resp.status_code == 401


def test_sync_previous_parties_with_valid_secret(client, monkeypatch):
    import knesset_sync

    def fake_fetch():
        return [{'knesset_faction_id': '1096', 'name': 'Likud'}]

    monkeypatch.setattr(knesset_sync, 'fetch_current_factions', fake_fetch)

    resp = client.post('/api/admin/sync-previous-parties', headers={'X-Admin-Secret': 'test-admin-secret'})
    assert resp.status_code == 200
    assert resp.get_json() == {'synced': 1}
```
```bash
python -m pytest tests/test_app.py -v
```
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/knesset_sync.py \
        ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/
git commit -m "Backend: admin auth + Knesset OData sync for previous_parties"
git push
```

---

## Task 10: Admin CRUD for `upcoming_parties`

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py`, `tests/test_app.py`

**Interfaces:**
- Produces: `queries.create_upcoming_party(conn, name) -> int`, `queries.rename_upcoming_party(conn, party_id, new_name) -> bool`, `queries.delete_upcoming_party(conn, party_id) -> bool`. Routes: `POST /api/admin/upcoming-parties`, `PATCH /api/admin/upcoming-parties/<id>`, `DELETE /api/admin/upcoming-parties/<id>` — all behind `require_admin`.

- [ ] **Step 1: Write the failing tests**

```python
# add to tests/test_queries.py
def test_create_rename_delete_upcoming_party(conn):
    import queries

    party_id = queries.create_upcoming_party(conn, 'New Party')
    assert party_id > 0

    assert queries.rename_upcoming_party(conn, party_id, 'Renamed Party') is True
    cur = conn.cursor()
    cur.execute('SELECT name FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 'Renamed Party'
    cur.close()

    assert queries.delete_upcoming_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_upcoming_party(conn, 999999, 'Nope') is False
    assert queries.delete_upcoming_party(conn, 999999) is False
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: FAIL — `AttributeError: module 'queries' has no attribute 'create_upcoming_party'`.

- [ ] **Step 3: Add the CRUD functions to `queries.py`**

```python
def create_upcoming_party(conn, name):
    cur = conn.cursor()
    cur.execute('INSERT INTO upcoming_parties (name) VALUES (%s) RETURNING id', (name,))
    party_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    return party_id


def rename_upcoming_party(conn, party_id, new_name):
    cur = conn.cursor()
    cur.execute('UPDATE upcoming_parties SET name = %s, updated_at = NOW() WHERE id = %s', (new_name, party_id))
    updated = cur.rowcount > 0
    conn.commit()
    cur.close()
    return updated


def delete_upcoming_party(conn, party_id):
    cur = conn.cursor()
    cur.execute('DELETE FROM upcoming_parties WHERE id = %s', (party_id,))
    deleted = cur.rowcount > 0
    conn.commit()
    cur.close()
    return deleted
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python -m pytest tests/test_queries.py -v
```
Expected: PASS.

- [ ] **Step 5: Wire the routes into `app.py`**

```python
@app.route('/api/admin/upcoming-parties', methods=['POST'])
@require_admin
def create_upcoming_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    party_id = queries.create_upcoming_party(conn, name)
    conn.close()
    return jsonify({'id': party_id, 'name': name}), 201


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_upcoming_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    updated = queries.rename_upcoming_party(conn, party_id, name)
    conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name': name})


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['DELETE'])
@require_admin
def delete_upcoming_party_route(party_id):
    conn = db.get_db()
    deleted = queries.delete_upcoming_party(conn, party_id)
    conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204
```

- [ ] **Step 6: Test the routes end-to-end**

```python
# add to tests/test_app.py
def test_upcoming_party_admin_crud(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Test Party'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_id}', json={'name': 'Renamed'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 404
```
```bash
python -m pytest tests/test_app.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/
git commit -m "Backend: admin CRUD for upcoming_parties"
git push
```

---

## Task 11: Backend Dockerfile

**Files:**
- Create: `ansible-project/roles/backend/files/backend/Dockerfile`
- Create: `ansible-project/roles/backend/files/backend/.dockerignore`

**Interfaces:**
- Produces: a `voteball-backend:<tag>` image, non-root (`uid 1000`), matching S3App's backend Dockerfile pattern exactly. Consumed by Task 19's `docker build`.

- [ ] **Step 1: Write `Dockerfile`**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py db.py queries.py knesset_sync.py schema.sql seed.sql .
USER appuser
CMD ["python", "app.py"]
```

- [ ] **Step 2: Write `.dockerignore`**

```
tests/
__pycache__/
*.pyc
.pytest_cache/
.env
*.log
```

- [ ] **Step 3: Verify the image builds locally**

```bash
cd "/home/latnook/Documents/Voteball/ansible-project/roles/backend/files/backend"
docker build -t voteball-backend:1.0 .
```
Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/backend/files/backend/Dockerfile \
        ansible-project/roles/backend/files/backend/.dockerignore
git commit -m "Backend: Dockerfile (non-root, matches S3App pattern)"
git push
```

---

## Task 12: Worker — rollup recomputation

**Files:**
- Create: `ansible-project/roles/worker/files/worker/db.py`
- Create: `ansible-project/roles/worker/files/worker/rollups.py`
- Create: `ansible-project/roles/worker/files/worker/requirements.txt`
- Test: `ansible-project/roles/worker/files/worker/tests/conftest.py`
- Test: `ansible-project/roles/worker/files/worker/tests/test_rollups.py`

**Interfaces:**
- Produces: `rollups.recompute(conn)` — truncates and repopulates `rollup_previous`/`rollup_upcoming` from `votes`/`vote_upcoming_parties`. No shared Python module with the backend (each container's files/ directory is independently copied and built, per the "independent copies" decision — `db.py` here is a near-duplicate of the backend's, not imported across containers).

- [ ] **Step 1: `requirements.txt`**

```
psycopg2-binary==2.9.11
boto3==1.42.85
pytest==8.3.4
```

- [ ] **Step 2: Write `db.py`** (same shape as the backend's, no `init_db` — the worker never creates schema, only the backend does)

```python
import os
import psycopg2

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ.get('DB_NAME', 'postgres')
DB_USER = os.environ.get('DB_USER', 'postgres')
DB_PASS = os.environ['DB_PASS']
DB_SSLMODE = os.environ.get('DB_SSLMODE', 'require')


def get_db():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS,
        sslmode=DB_SSLMODE
    )
```

- [ ] **Step 3: Write the failing test**

```python
# tests/conftest.py
import os
import sys
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('DB_HOST', 'localhost')
os.environ.setdefault('DB_NAME', 'postgres')
os.environ.setdefault('DB_USER', 'postgres')
os.environ.setdefault('DB_PASS', 'test')
os.environ.setdefault('DB_SSLMODE', 'disable')

import db as db_module

SCHEMA = '''
CREATE TABLE leagues (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE clubs (id SERIAL PRIMARY KEY, league_id INTEGER NOT NULL REFERENCES leagues(id), name TEXT NOT NULL);
CREATE TABLE previous_parties (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE upcoming_parties (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE votes (
    id SERIAL PRIMARY KEY,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    club_id INTEGER REFERENCES clubs(id),
    previous_vote_status TEXT NOT NULL,
    previous_party_id INTEGER REFERENCES previous_parties(id),
    upcoming_vote_status TEXT NOT NULL,
    cookie_token TEXT NOT NULL UNIQUE
);
CREATE TABLE vote_upcoming_parties (
    vote_id INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id) ON DELETE CASCADE,
    PRIMARY KEY (vote_id, upcoming_party_id)
);
CREATE TABLE alert_state (id INTEGER PRIMARY KEY DEFAULT 1, last_seen_total INTEGER NOT NULL DEFAULT 0);
CREATE TABLE rollup_previous (league_id INTEGER NOT NULL, club_id INTEGER, previous_party_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_upcoming (league_id INTEGER NOT NULL, club_id INTEGER, upcoming_party_id INTEGER, vote_count INTEGER NOT NULL);
'''


@pytest.fixture
def conn():
    connection = db_module.get_db()
    cur = connection.cursor()
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, votes, rollup_previous,
            rollup_upcoming, clubs, leagues, previous_parties, upcoming_parties,
            alert_state CASCADE
    ''')
    cur.execute(SCHEMA)
    connection.commit()
    cur.close()
    yield connection
    connection.close()
```

```python
# tests/test_rollups.py
def _seed_votes(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party B') RETURNING id")
    party_b = cur.fetchone()[0]

    # Vote 1: voted Party X, considering both A and B
    cur.execute(
        '''INSERT INTO votes (league_id, club_id, previous_vote_status, previous_party_id,
           upcoming_vote_status, cookie_token) VALUES (%s, %s, 'voted', %s, 'considering', 't1') RETURNING id''',
        (league_id, club_id, party_x)
    )
    v1 = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v1, party_a))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v1, party_b))

    # Vote 2: did not vote previously, undecided now
    cur.execute(
        '''INSERT INTO votes (league_id, club_id, previous_vote_status, previous_party_id,
           upcoming_vote_status, cookie_token) VALUES (%s, %s, 'did_not_vote', NULL, 'undecided', 't2')''',
        (league_id, club_id)
    )

    conn.commit()
    cur.close()
    return league_id, club_id, party_x, party_a, party_b


def test_recompute_builds_previous_and_upcoming_rollups(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT previous_party_id, vote_count FROM rollup_previous ORDER BY previous_party_id NULLS LAST')
    previous_rows = cur.fetchall()
    assert (party_x, 1) in previous_rows
    assert (None, 1) in previous_rows

    cur.execute('SELECT upcoming_party_id, vote_count FROM rollup_upcoming ORDER BY upcoming_party_id NULLS LAST')
    upcoming_rows = cur.fetchall()
    assert (party_a, 1) in upcoming_rows
    assert (party_b, 1) in upcoming_rows
    assert (None, 1) in upcoming_rows  # the undecided vote
    cur.close()


def test_recompute_is_idempotent(conn):
    import rollups
    _seed_votes(conn)

    rollups.recompute(conn)
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM rollup_previous')
    first_count = cur.fetchone()[0]
    cur.close()

    rollups.recompute(conn)
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM rollup_previous')
    second_count = cur.fetchone()[0]
    cur.close()

    assert first_count == second_count
```

- [ ] **Step 4: Run test to verify it fails**

```bash
cd "/home/latnook/Documents/Voteball/ansible-project/roles/worker/files/worker"
python -m pytest tests/test_rollups.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'rollups'`.

- [ ] **Step 5: Write `rollups.py`**

```python
def recompute(conn):
    cur = conn.cursor()

    cur.execute('TRUNCATE rollup_previous')
    cur.execute('''
        INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count)
        SELECT league_id, club_id, previous_party_id, COUNT(*)
        FROM votes
        GROUP BY league_id, club_id, previous_party_id
    ''')

    cur.execute('TRUNCATE rollup_upcoming')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT v.league_id, v.club_id, vup.upcoming_party_id, COUNT(*)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.league_id, v.club_id, vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT league_id, club_id, NULL, COUNT(*)
        FROM votes
        WHERE upcoming_vote_status = 'undecided'
        GROUP BY league_id, club_id
    ''')

    conn.commit()
    cur.close()
```

- [ ] **Step 6: Run test to verify it passes**

```bash
python -m pytest tests/test_rollups.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/worker/files/worker/db.py \
        ansible-project/roles/worker/files/worker/rollups.py \
        ansible-project/roles/worker/files/worker/requirements.txt \
        ansible-project/roles/worker/files/worker/tests/
git commit -m "Worker: rollup recomputation, TDD"
git push
```

---

## Task 13: Worker — milestone SNS alerts

**Files:**
- Create: `ansible-project/roles/worker/files/worker/alerts.py`
- Test: `ansible-project/roles/worker/files/worker/tests/test_alerts.py`

**Interfaces:**
- Produces: `alerts.MILESTONES = [100, 500, 1000, 2500, 5000, 10000]`, `alerts.milestones_crossed(previous_total, current_total) -> list[int]` (pure function), `alerts.check_and_notify(conn, sns_client, topic_arn)` (reads/updates `alert_state`, publishes to SNS for each newly crossed milestone).

- [ ] **Step 1: Write the failing test for the pure function**

```python
# tests/test_alerts.py
import alerts


def test_milestones_crossed_single():
    assert alerts.milestones_crossed(90, 105) == [100]


def test_milestones_crossed_multiple_in_one_jump():
    assert alerts.milestones_crossed(50, 600) == [100, 500]


def test_milestones_crossed_none():
    assert alerts.milestones_crossed(100, 150) == []


def test_milestones_crossed_exact_boundary():
    assert alerts.milestones_crossed(99, 100) == [100]
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python -m pytest tests/test_alerts.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'alerts'`.

- [ ] **Step 3: Write `alerts.py`**

```python
MILESTONES = [100, 500, 1000, 2500, 5000, 10000]


def milestones_crossed(previous_total, current_total):
    return [m for m in MILESTONES if previous_total < m <= current_total]


def check_and_notify(conn, sns_client, topic_arn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes')
    current_total = cur.fetchone()[0]

    cur.execute('SELECT last_seen_total FROM alert_state WHERE id = 1')
    previous_total = cur.fetchone()[0]

    for milestone in milestones_crossed(previous_total, current_total):
        sns_client.publish(
            TopicArn=topic_arn,
            Subject='Voteball milestone reached',
            Message=f'Voteball has reached {milestone} votes! Current total: {current_total}.'
        )

    if current_total != previous_total:
        cur.execute('UPDATE alert_state SET last_seen_total = %s WHERE id = 1', (current_total,))
        conn.commit()
    cur.close()
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python -m pytest tests/test_alerts.py -v
```
Expected: PASS.

- [ ] **Step 5: Write the integration test with a fake SNS client**

```python
# add to tests/test_alerts.py
class FakeSNSClient:
    def __init__(self):
        self.published = []

    def publish(self, TopicArn, Subject, Message):
        self.published.append((TopicArn, Subject, Message))


def test_check_and_notify_publishes_and_updates_state(conn):
    import alerts
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    for i in range(100):
        cur.execute(
            '''INSERT INTO votes (league_id, previous_vote_status, upcoming_vote_status, cookie_token)
               VALUES (%s, 'did_not_vote', 'undecided', %s)''',
            (league_id, f'token-{i}')
        )
    conn.commit()
    cur.close()

    fake_sns = FakeSNSClient()
    alerts.check_and_notify(conn, fake_sns, 'arn:aws:sns:il-central-1:000000000000:test')

    assert len(fake_sns.published) == 1
    assert '100 votes' in fake_sns.published[0][2]

    cur = conn.cursor()
    cur.execute('SELECT last_seen_total FROM alert_state WHERE id = 1')
    assert cur.fetchone()[0] == 100
    cur.close()

    # Running again with no new votes must not re-notify
    alerts.check_and_notify(conn, fake_sns, 'arn:aws:sns:il-central-1:000000000000:test')
    assert len(fake_sns.published) == 1
```

Needs `alert_state` seeded — add to `conftest.py`'s `conn` fixture, right after the schema is created:
```python
    cur = connection.cursor()
    cur.execute('INSERT INTO alert_state (id, last_seen_total) VALUES (1, 0)')
    connection.commit()
    cur.close()
```

- [ ] **Step 6: Run test to verify it passes**

```bash
python -m pytest tests/test_alerts.py -v
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/worker/files/worker/alerts.py \
        ansible-project/roles/worker/files/worker/tests/
git commit -m "Worker: milestone SNS alerts, TDD"
git push
```

---

## Task 14: Worker main loop and Dockerfile

**Files:**
- Create: `ansible-project/roles/worker/files/worker/worker.py`
- Create: `ansible-project/roles/worker/files/worker/Dockerfile`
- Create: `ansible-project/roles/worker/files/worker/.dockerignore`

**Interfaces:**
- Produces: a `voteball-worker:<tag>` image, non-root, running the poll loop from Tasks 12–13 every 30 seconds (matching S3App's worker interval).

- [ ] **Step 1: Write `worker.py`**

```python
import os
import time
import boto3
import db
import rollups
import alerts

SNS_TOPIC = os.environ['SNS_TOPIC']
AWS_REGION = os.environ.get('AWS_REGION', 'il-central-1')

if __name__ == '__main__':
    sns = boto3.client('sns', region_name=AWS_REGION)
    print('Voteball worker started...')
    while True:
        conn = db.get_db()
        rollups.recompute(conn)
        alerts.check_and_notify(conn, sns, SNS_TOPIC)
        conn.close()
        print('Rollups recomputed, milestones checked.')
        time.sleep(30)
```

- [ ] **Step 2: Write `Dockerfile`**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py db.py rollups.py alerts.py .
USER appuser
CMD ["python", "worker.py"]
```

- [ ] **Step 3: Write `.dockerignore`**

```
tests/
__pycache__/
*.pyc
.pytest_cache/
.env
*.log
```

- [ ] **Step 4: Verify the image builds locally**

```bash
cd "/home/latnook/Documents/Voteball/ansible-project/roles/worker/files/worker"
docker build -t voteball-worker:1.0 .
```
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/worker/files/worker/worker.py \
        ansible-project/roles/worker/files/worker/Dockerfile \
        ansible-project/roles/worker/files/worker/.dockerignore
git commit -m "Worker: main loop + Dockerfile (non-root)"
git push
```

---

## Task 15: Frontend — voting form

**Files:**
- Create: `ansible-project/roles/frontend/files/nginx/index.html`
- Create: `ansible-project/roles/frontend/files/nginx/vote.js`
- Create: `ansible-project/roles/frontend/files/nginx/style.css`

**Interfaces:**
- Consumes: `GET /api/options`, `POST /api/vote` (Tasks 6, 7).
- Produces: a static voting page that redirects to `results.html` on success. No unit tests — matching S3App's precedent of no test coverage for static frontend markup; verified manually in Task 21.

- [ ] **Step 1: Write `style.css`**

```css
body { font-family: system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
h1 { font-size: 1.5rem; }
fieldset { margin-bottom: 1.5rem; border: 1px solid #ccc; border-radius: 8px; padding: 1rem; }
legend { font-weight: 600; padding: 0 0.5rem; }
label { display: block; margin: 0.4rem 0; }
select, button { font-size: 1rem; padding: 0.4rem; }
button { cursor: pointer; background: #1a73e8; color: white; border: none; border-radius: 6px; padding: 0.6rem 1.2rem; }
button:disabled { background: #999; }
.error { color: #c00; }
```

- [ ] **Step 2: Write `index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Voteball</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <h1>Voteball</h1>
  <p>Football fandom vs. how you vote — anonymous, one vote per browser.</p>

  <form id="vote-form">
    <fieldset>
      <legend>1. League</legend>
      <label>League: <select id="league-select" required></select></label>
      <label>Club (optional, or leave blank if you just follow the league):
        <select id="club-select"><option value="">— just the league —</option></select>
      </label>
    </fieldset>

    <fieldset>
      <legend>2. Current Knesset — who did you vote for?</legend>
      <div id="previous-party-options"></div>
      <label><input type="radio" name="previous" value="did_not_vote" required> Didn't vote / not eligible</label>
    </fieldset>

    <fieldset>
      <legend>3. Upcoming election — who are you considering?</legend>
      <div id="upcoming-party-options"></div>
      <label><input type="checkbox" id="undecided-checkbox"> Undecided / prefer not to say</label>
    </fieldset>

    <button type="submit">Submit vote</button>
    <p class="error" id="error-message"></p>
  </form>

  <script src="vote.js"></script>
</body>
</html>
```

- [ ] **Step 3: Write `vote.js`**

```javascript
async function loadOptions() {
  const res = await fetch('/api/options');
  const data = await res.json();

  const leagueSelect = document.getElementById('league-select');
  data.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = l.name;
    leagueSelect.appendChild(opt);
  });

  const clubSelect = document.getElementById('club-select');
  function renderClubs() {
    clubSelect.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
    const leagueId = parseInt(leagueSelect.value, 10);
    data.clubs.filter(c => c.league_id === leagueId).forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.id;
      opt.textContent = c.name;
      clubSelect.appendChild(opt);
    });
  }
  leagueSelect.addEventListener('change', renderClubs);
  renderClubs();

  const prevDiv = document.getElementById('previous-party-options');
  data.previous_parties.forEach(p => {
    const label = document.createElement('label');
    label.innerHTML = `<input type="radio" name="previous" value="${p.id}"> ${p.name}`;
    prevDiv.appendChild(label);
  });

  const upcomingDiv = document.getElementById('upcoming-party-options');
  data.upcoming_parties.forEach(p => {
    const label = document.createElement('label');
    label.innerHTML = `<input type="checkbox" class="upcoming-checkbox" value="${p.id}"> ${p.name}`;
    upcomingDiv.appendChild(label);
  });
}

function selectedUpcomingPartyIds() {
  return Array.from(document.querySelectorAll('.upcoming-checkbox:checked')).map(cb => parseInt(cb.value, 10));
}

document.getElementById('undecided-checkbox').addEventListener('change', (e) => {
  document.querySelectorAll('.upcoming-checkbox').forEach(cb => {
    cb.disabled = e.target.checked;
    if (e.target.checked) cb.checked = false;
  });
});

document.getElementById('vote-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('error-message');
  errorEl.textContent = '';

  const leagueId = parseInt(document.getElementById('league-select').value, 10);
  const clubValue = document.getElementById('club-select').value;
  const previousChoice = document.querySelector('input[name="previous"]:checked');
  const undecided = document.getElementById('undecided-checkbox').checked;
  const upcomingIds = selectedUpcomingPartyIds();

  if (!leagueId || !previousChoice) {
    errorEl.textContent = 'Please fill in all required fields.';
    return;
  }
  if (!undecided && upcomingIds.length === 0) {
    errorEl.textContent = 'Pick at least one party you\'re considering, or mark yourself undecided.';
    return;
  }

  const body = {
    league_id: leagueId,
    club_id: clubValue ? parseInt(clubValue, 10) : null,
    previous_vote_status: previousChoice.value === 'did_not_vote' ? 'did_not_vote' : 'voted',
    previous_party_id: previousChoice.value === 'did_not_vote' ? null : parseInt(previousChoice.value, 10),
    upcoming_vote_status: undecided ? 'undecided' : 'considering',
    upcoming_party_ids: undecided ? [] : upcomingIds,
  };

  const res = await fetch('/api/vote', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  if (res.status === 409) {
    window.location.href = 'results.html';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = 'Something went wrong submitting your vote.';
    return;
  }
  window.location.href = 'results.html';
});

loadOptions();
```

- [ ] **Step 4: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/frontend/files/nginx/index.html \
        ansible-project/roles/frontend/files/nginx/vote.js \
        ansible-project/roles/frontend/files/nginx/style.css
git commit -m "Frontend: voting form"
git push
```

---

## Task 16: Frontend — results dashboard

**Files:**
- Create: `ansible-project/roles/frontend/files/nginx/results.html`
- Create: `ansible-project/roles/frontend/files/nginx/results.js`

**Interfaces:**
- Consumes: `GET /api/options`, `GET /api/results?by=club|league|party` (Tasks 6, 8).
- Produces: a static dashboard with the club/league ↔ party toggle described in the design spec.

- [ ] **Step 1: Write `results.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Voteball — Results</title>
  <link rel="stylesheet" href="style.css">
  <style>
    .bar-row { display: flex; align-items: center; margin: 0.3rem 0; }
    .bar-label { width: 220px; font-size: 0.9rem; }
    .bar-track { flex: 1; background: #eee; border-radius: 4px; height: 1.2rem; margin: 0 0.5rem; }
    .bar-fill { background: #1a73e8; height: 100%; border-radius: 4px; }
    .bar-count { width: 40px; text-align: right; font-size: 0.85rem; }
    .toggle { margin-bottom: 1rem; }
  </style>
</head>
<body>
  <h1>Voteball — Results</h1>
  <p id="total-votes"></p>

  <div class="toggle">
    <label><input type="radio" name="mode" value="club-league" checked> Start from a club/league</label>
    <label><input type="radio" name="mode" value="party"> Start from a party</label>
  </div>

  <div id="club-league-mode">
    <label>League: <select id="league-picker"></select></label>
    <label>Club (optional): <select id="club-picker"><option value="">— whole league —</option></select></label>
  </div>

  <div id="party-mode" style="display:none">
    <label>Party type:
      <select id="party-type-picker">
        <option value="previous">Previous (current Knesset)</option>
        <option value="upcoming">Upcoming election</option>
      </select>
    </label>
    <label>Party: <select id="party-picker"></select></label>
  </div>

  <h2>Previous Knesset vote breakdown</h2>
  <div id="previous-results"></div>

  <h2>Upcoming election breakdown</h2>
  <div id="upcoming-results"></div>

  <script src="results.js"></script>
</body>
</html>
```

- [ ] **Step 2: Write `results.js`**

```javascript
let optionsData = null;

function renderBars(containerId, rows, nameLookup) {
  const container = document.getElementById(containerId);
  container.innerHTML = '';
  const total = rows.reduce((sum, r) => sum + r.count, 0) || 1;
  rows.sort((a, b) => b.count - a.count);
  rows.forEach(r => {
    const label = nameLookup(r);
    const pct = Math.round((r.count / total) * 100);
    const row = document.createElement('div');
    row.className = 'bar-row';
    row.innerHTML = `
      <div class="bar-label">${label}</div>
      <div class="bar-track"><div class="bar-fill" style="width:${pct}%"></div></div>
      <div class="bar-count">${r.count}</div>
    `;
    container.appendChild(row);
  });
}

function previousPartyName(id) {
  if (id === null) return 'Did not vote';
  const p = optionsData.previous_parties.find(p => p.id === id);
  return p ? p.name : `#${id}`;
}

function upcomingPartyName(id) {
  if (id === null) return 'Undecided';
  const p = optionsData.upcoming_parties.find(p => p.id === id);
  return p ? p.name : `#${id}`;
}

function clubOrLeagueName(row) {
  if (row.club_id) {
    const c = optionsData.clubs.find(c => c.id === row.club_id);
    return c ? c.name : `club #${row.club_id}`;
  }
  const l = optionsData.leagues.find(l => l.id === row.league_id);
  return l ? `${l.name} (league-wide)` : `league #${row.league_id}`;
}

async function loadResultsByClubOrLeague() {
  const clubId = document.getElementById('club-picker').value;
  const leagueId = document.getElementById('league-picker').value;

  const query = clubId ? `by=club&id=${clubId}` : `by=league&id=${leagueId}`;
  const res = await fetch(`/api/results?${query}`);
  const data = await res.json();

  renderBars('previous-results', data.previous.map(r => ({ count: r.count, key: r.party_id })), r => previousPartyName(r.key));
  renderBars('upcoming-results', data.upcoming.map(r => ({ count: r.count, key: r.party_id })), r => upcomingPartyName(r.key));
}

async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const res = await fetch(`/api/results?by=party&type=${partyType}&id=${partyId}`);
  const data = await res.json();

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';
  document.getElementById(otherId).innerHTML = '<p>Switch party type to see this breakdown.</p>';
  renderBars(targetId, data.breakdown.map(r => ({ count: r.count, club_id: r.club_id, league_id: r.league_id })), clubOrLeagueName);
}

function renderPartyPicker() {
  const partyType = document.getElementById('party-type-picker').value;
  const picker = document.getElementById('party-picker');
  picker.innerHTML = '';
  const list = partyType === 'previous' ? optionsData.previous_parties : optionsData.upcoming_parties;
  list.forEach(p => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = p.name;
    picker.appendChild(opt);
  });
  loadResultsByParty();
}

async function init() {
  const res = await fetch('/api/options');
  optionsData = await res.json();

  const leaguePicker = document.getElementById('league-picker');
  optionsData.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = l.name;
    leaguePicker.appendChild(opt);
  });

  const clubPicker = document.getElementById('club-picker');
  function renderClubs() {
    clubPicker.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
    const leagueId = parseInt(leaguePicker.value, 10);
    optionsData.clubs.filter(c => c.league_id === leagueId).forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.id;
      opt.textContent = c.name;
      clubPicker.appendChild(opt);
    });
  }
  leaguePicker.addEventListener('change', () => { renderClubs(); loadResultsByClubOrLeague(); });
  clubPicker.addEventListener('change', loadResultsByClubOrLeague);
  renderClubs();

  document.querySelectorAll('input[name="mode"]').forEach(radio => {
    radio.addEventListener('change', () => {
      const isClubLeague = document.querySelector('input[name="mode"]:checked').value === 'club-league';
      document.getElementById('club-league-mode').style.display = isClubLeague ? 'block' : 'none';
      document.getElementById('party-mode').style.display = isClubLeague ? 'none' : 'block';
      if (isClubLeague) loadResultsByClubOrLeague(); else renderPartyPicker();
    });
  });

  document.getElementById('party-type-picker').addEventListener('change', renderPartyPicker);
  document.getElementById('party-picker').addEventListener('change', loadResultsByParty);

  loadResultsByClubOrLeague();
}

init();
```

- [ ] **Step 3: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/frontend/files/nginx/results.html \
        ansible-project/roles/frontend/files/nginx/results.js
git commit -m "Frontend: results dashboard with club/league <-> party toggle"
git push
```

---

## Task 17: Frontend Dockerfile and nginx config

**Files:**
- Create: `ansible-project/roles/frontend/files/nginx/Dockerfile`
- Create: `ansible-project/roles/frontend/files/nginx/.dockerignore`
- Create: `ansible-project/roles/frontend/templates/nginx.conf.j2`

**Interfaces:**
- Produces: a `voteball-nginx:<tag>` image serving the static frontend and proxying `/api/` to the in-cluster `backend` Service on port 5000 — same proxy pattern as S3App's frontend.

- [ ] **Step 1: Write `Dockerfile`**

```dockerfile
FROM nginx:alpine
COPY index.html results.html vote.js results.js style.css /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
```

- [ ] **Step 2: Write `.dockerignore`**

```
nginx.conf.j2
```

- [ ] **Step 3: Write `nginx.conf.j2`**

```
# Managed by Ansible — do not edit manually
server {
    listen 80;
    server_name {{ frontend_domain }};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name {{ frontend_domain }};

    ssl_certificate /etc/letsencrypt/live/{{ frontend_domain }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ frontend_domain }}/privkey.pem;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://backend:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

- [ ] **Step 4: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/frontend/files/nginx/Dockerfile \
        ansible-project/roles/frontend/files/nginx/.dockerignore \
        ansible-project/roles/frontend/templates/nginx.conf.j2
git commit -m "Frontend: Dockerfile + nginx config template"
git push
```

---

## Task 18: Helm chart

**Files:**
- Create: `charts/voteball/Chart.yaml`
- Create: `charts/voteball/values.yaml`
- Create: `charts/voteball/templates/serviceaccounts.yaml`
- Create: `charts/voteball/templates/backend-deployment.yaml`, `backend-service.yaml`
- Create: `charts/voteball/templates/worker-deployment.yaml`
- Create: `charts/voteball/templates/frontend-deployment.yaml`, `frontend-service.yaml`
- Create: `k8s/namespace.yaml`

**Interfaces:**
- Consumes: `app-config` ConfigMap and `app-secret` Secret (rendered by Task 19's k3s role) via `envFrom`, same convention as S3App.
- Produces: a chart installable as `helm upgrade --install voteball charts/voteball --namespace voteball-app`.

- [ ] **Step 1: `k8s/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: voteball-app
```

- [ ] **Step 2: `Chart.yaml`**

```yaml
apiVersion: v2
name: voteball
description: Voteball backend/frontend/worker Deployments and Services for the k3s single-node cluster
type: application
version: 0.1.0
appVersion: "1.0"
```

- [ ] **Step 3: `values.yaml`**

```yaml
image:
  tag: "1.0"
  pullPolicy: IfNotPresent

backend:
  replicas: 2
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 250m
      memory: 256Mi

frontend:
  replicas: 2
  resources:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

worker:
  # Singleton poller, not a request-serving tier — 2 replicas would just be
  # 2 processes independently polling and computing identical rollups.
  replicas: 1
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

- [ ] **Step 4: `templates/serviceaccounts.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: {{ .Release.Namespace }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend
  namespace: {{ .Release.Namespace }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: worker
  namespace: {{ .Release.Namespace }}
```

- [ ] **Step 5: `templates/backend-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: {{ .Release.Namespace }}
  labels:
    app: backend
spec:
  replicas: {{ .Values.backend.replicas }}
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      serviceAccountName: backend
      containers:
        - name: backend
          image: "voteball-backend:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 5000
          envFrom:
            - configMapRef:
                name: app-config
            - secretRef:
                name: app-secret
          resources:
            requests:
              cpu: {{ .Values.backend.resources.requests.cpu }}
              memory: {{ .Values.backend.resources.requests.memory }}
            limits:
              cpu: {{ .Values.backend.resources.limits.cpu }}
              memory: {{ .Values.backend.resources.limits.memory }}
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 20
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
```

- [ ] **Step 6: `templates/backend-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: {{ .Release.Namespace }}
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 5000
      targetPort: 5000
```

- [ ] **Step 7: `templates/worker-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: {{ .Release.Namespace }}
  labels:
    app: worker
spec:
  replicas: {{ .Values.worker.replicas }}
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      serviceAccountName: worker
      containers:
        - name: worker
          image: "voteball-worker:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          envFrom:
            - configMapRef:
                name: app-config
            - secretRef:
                name: app-secret
          resources:
            requests:
              cpu: {{ .Values.worker.resources.requests.cpu }}
              memory: {{ .Values.worker.resources.requests.memory }}
            limits:
              cpu: {{ .Values.worker.resources.limits.cpu }}
              memory: {{ .Values.worker.resources.limits.memory }}
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
```

- [ ] **Step 8: `templates/frontend-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: {{ .Release.Namespace }}
  labels:
    app: frontend
spec:
  replicas: {{ .Values.frontend.replicas }}
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      serviceAccountName: frontend
      containers:
        - name: frontend
          image: "voteball-nginx:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 80
            - containerPort: 443
          volumeMounts:
            - name: letsencrypt
              mountPath: /etc/letsencrypt
              readOnly: true
          resources:
            requests:
              cpu: {{ .Values.frontend.resources.requests.cpu }}
              memory: {{ .Values.frontend.resources.requests.memory }}
            limits:
              cpu: {{ .Values.frontend.resources.limits.cpu }}
              memory: {{ .Values.frontend.resources.limits.memory }}
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["CHOWN", "SETUID", "SETGID"]
      volumes:
        - name: letsencrypt
          hostPath:
            path: /etc/letsencrypt
            type: Directory
```

- [ ] **Step 9: `templates/frontend-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: {{ .Release.Namespace }}
spec:
  type: LoadBalancer
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
```

- [ ] **Step 10: Verify the chart renders**

```bash
cd "/home/latnook/Documents/Voteball"
helm template voteball charts/voteball --namespace voteball-app | head -50
```
Expected: valid YAML output, no template errors.

- [ ] **Step 11: Commit**

```bash
git add charts/voteball k8s/namespace.yaml
git commit -m "Add Helm chart: backend/worker/frontend Deployments+Services"
git push
```

---

## Task 19: `k3s` Ansible role

**Files:**
- Modify: `ansible-project/roles/k3s/tasks/main.yml`
- Modify: `ansible-project/roles/k3s/defaults/main.yml`
- Create: `ansible-project/roles/k3s/handlers/main.yml` (already copied in Task 1 — confirm content matches)

**Interfaces:**
- Consumes: `frontend_domain`, `db_host`, `db_name`, `db_user`, `db_pass`, `sns_topic`, `aws_region`, `admin_secret`, `certbot_email` (Ansible inventory/group_vars variables — `admin_secret` new, added by Task 20's `secrets.yml`).
- Produces: a running k3s cluster with the Helm release `voteball` installed in namespace `voteball-app`.

- [ ] **Step 1: Edit `defaults/main.yml`**

```yaml
app_version: "1.0"
certbot_email: "8847444@proton.me"
```

- [ ] **Step 2: Rewrite `tasks/main.yml`** — same structure as S3App's, with these substitutions: `s3app` → `voteball`, `devops-app` → `voteball-app`, no `S3_BUCKET` ConfigMap key, add `ADMIN_SECRET` to the Secret, Helm release name `voteball` instead of `s3app`.

```yaml
---
- name: Install Docker
  dnf:
    name: docker
    state: present

- name: Enable and start Docker service
  systemd:
    name: docker
    state: started
    enabled: true

- name: Add ec2-user to docker group
  user:
    name: ec2-user
    groups: docker
    append: true

- name: Install k3s (Docker-backed)
  shell: |
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--docker --disable=traefik" sh -
  args:
    creates: /usr/local/bin/k3s

- name: Wait for k3s to be ready
  command: k3s kubectl get nodes
  register: k3s_nodes
  until: "'Ready' in k3s_nodes.stdout"
  retries: 12
  delay: 5
  changed_when: false

- name: Symlink kubectl to k3s kubectl for convenience
  file:
    src: /usr/local/bin/k3s
    dest: /usr/local/bin/kubectl
    state: link
  failed_when: false

- name: Install Helm
  shell: |
    curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  args:
    creates: /usr/local/bin/helm

- name: Obtain/renew the TLS cert and enable its renewal timer
  include_tasks: "{{ role_path }}/../app-compose/tasks/certbot.yml"

- name: Create app directory structure
  file:
    path: "/home/ec2-user/voteball/{{ item }}"
    state: directory
    owner: ec2-user
    group: ec2-user
  loop:
    - backend
    - worker
    - nginx

- name: Copy backend build context
  copy:
    src: "{{ role_path }}/../backend/files/backend/"
    dest: /home/ec2-user/voteball/backend/

- name: Copy worker build context
  copy:
    src: "{{ role_path }}/../worker/files/worker/"
    dest: /home/ec2-user/voteball/worker/

- name: Copy nginx build context (image, not the templated config yet)
  copy:
    src: "{{ role_path }}/../frontend/files/nginx/"
    dest: /home/ec2-user/voteball/nginx/

- name: Render nginx.conf from the frontend role's template
  template:
    src: "{{ role_path }}/../frontend/templates/nginx.conf.j2"
    dest: /home/ec2-user/voteball/nginx/nginx.conf.j2.rendered

- name: Bake the rendered nginx.conf into the nginx build context
  copy:
    remote_src: true
    src: /home/ec2-user/voteball/nginx/nginx.conf.j2.rendered
    dest: /home/ec2-user/voteball/nginx/nginx.conf

- name: Build backend image
  command: docker build -t voteball-backend:{{ app_version }} /home/ec2-user/voteball/backend

- name: Build worker image
  command: docker build -t voteball-worker:{{ app_version }} /home/ec2-user/voteball/worker

- name: Build nginx image
  command: docker build -t voteball-nginx:{{ app_version }} /home/ec2-user/voteball/nginx

- name: Create k8s directory on the node
  file:
    path: /home/ec2-user/k8s
    state: directory
    owner: ec2-user
    group: ec2-user

- name: Copy namespace.yaml to the node
  copy:
    src: "{{ playbook_dir }}/../k8s/namespace.yaml"
    dest: /home/ec2-user/k8s/namespace.yaml

- name: Apply namespace first (everything else depends on it existing)
  command: kubectl apply -f /home/ec2-user/k8s/namespace.yaml

- name: Render the app-config ConfigMap manifest in-memory
  set_fact:
    app_config_manifest: |
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: app-config
        namespace: voteball-app
      data:
        DB_HOST: "{{ db_host }}"
        DB_NAME: "{{ db_name | default('postgres') }}"
        DB_SSLMODE: "{{ db_sslmode | default('require') }}"
        SNS_TOPIC: "{{ sns_topic }}"
        AWS_REGION: "{{ aws_region }}"

- name: Apply the app-config ConfigMap via stdin
  command: kubectl apply -f -
  args:
    stdin: "{{ app_config_manifest }}"
  register: configmap_apply_result
  changed_when: "'unchanged' not in configmap_apply_result.stdout"
  notify: restart app deployments

- name: Render the app-secret Secret manifest in-memory
  set_fact:
    app_secret_manifest: |
      apiVersion: v1
      kind: Secret
      metadata:
        name: app-secret
        namespace: voteball-app
      type: Opaque
      data:
        DB_USER: "{{ db_user | default('postgres') | b64encode }}"
        DB_PASS: "{{ db_pass | b64encode }}"
        ADMIN_SECRET: "{{ admin_secret | b64encode }}"
  no_log: true

- name: Apply the app-secret Secret via stdin
  command: kubectl apply -f -
  args:
    stdin: "{{ app_secret_manifest }}"
  register: secret_apply_result
  changed_when: "'unchanged' not in secret_apply_result.stdout"
  notify: restart app deployments
  no_log: true

- name: Remove any previous Helm chart directory on the node (clean slate)
  file:
    path: /home/ec2-user/charts/
    state: absent

- name: Copy the Helm chart to the node
  copy:
    src: "{{ playbook_dir }}/../charts/voteball"
    dest: /home/ec2-user/charts/

- name: Deploy the chart
  command: >
    helm upgrade --install voteball /home/ec2-user/charts/voteball
    --namespace voteball-app
    --set image.tag={{ app_version }}
  environment:
    KUBECONFIG: /etc/rancher/k3s/k3s.yaml

- name: Configure certbot to roll the frontend deployment after a real renewal
  lineinfile:
    path: /etc/sysconfig/certbot
    regexp: '^DEPLOY_HOOK='
    line: >-
      DEPLOY_HOOK="--deploy-hook 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      kubectl rollout restart deployment/frontend -n voteball-app'"

- name: Flush handlers now so a ConfigMap/Secret change restarts pods before we wait for Available
  meta: flush_handlers

- name: Wait for all deployments to report Available
  command: >
    kubectl wait --for=condition=Available deployment
    --all -n voteball-app --timeout=180s
  changed_when: false
```

- [ ] **Step 3: Confirm `handlers/main.yml`** (copied in Task 1 — update the namespace flag)

```yaml
---
- name: restart app deployments
  command: kubectl rollout restart deployment/backend deployment/worker -n voteball-app
```

- [ ] **Step 4: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/roles/k3s
git commit -m "k3s role: adapt for voteball (namespace, images, ConfigMap/Secret keys)"
git push
```

---

## Task 20: `site-k3s.yml` playbook and inventory secrets

**Files:**
- Create: `ansible-project/site-k3s.yml`
- Create: `ansible-project/ansible.cfg`
- Create: `ansible-project/inventories/voteball/group_vars/all/secrets.yml.example`

**Interfaces:**
- Consumes: Task 3's generated `inventories/voteball/hosts` and `group_vars/all/main.yml`.
- Produces: the entry point playbook run in Task 21.

- [ ] **Step 1: Write `site-k3s.yml`**

```yaml
---
- name: Deploy Voteball on k3s
  hosts: app
  become: true
  roles:
    - common
    - k3s
```

- [ ] **Step 2: Write `ansible.cfg`**

```ini
[defaults]
inventory = inventories/voteball
remote_user = ec2-user
private_key_file = ../Voteball-EC2-pem.pem
host_key_checking = False
roles_path = roles
```

- [ ] **Step 3: Write `secrets.yml.example`**

```yaml
# Copy this file to secrets.yml and fill in real values.
# secrets.yml is gitignored — never commit it.
db_pass: your_rds_master_password_here
admin_secret: your_admin_secret_here
```

Generate a real `admin_secret`:
```bash
openssl rand -hex 32
```

- [ ] **Step 4: Bootstrap secrets.yml**

```bash
cd "/home/latnook/Documents/Voteball/ansible-project"
mkdir -p inventories/voteball/group_vars/all
cp inventories/voteball/group_vars/all/secrets.yml.example inventories/voteball/group_vars/all/secrets.yml
# edit secrets.yml: set db_pass (matches terraform/voteball.tfvars) and admin_secret
```

- [ ] **Step 5: Commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add ansible-project/site-k3s.yml ansible-project/ansible.cfg \
        ansible-project/inventories/voteball/group_vars/all/secrets.yml.example
git commit -m "Add site-k3s.yml playbook, ansible.cfg, secrets.yml.example"
git push
```

---

## Task 21: Deploy and verify end-to-end

**Files:** none (deployment/verification only).

**Interfaces:** none — this task exercises everything built in Tasks 1–20 together.

- [ ] **Step 1: Confirm SSH access and IP allowlist**

```bash
curl -s https://checkip.amazonaws.com
```
Compare against `ssh_allowed_cidr` in `terraform/voteball.tfvars` — update and `terraform apply` first if it doesn't match.

- [ ] **Step 2: Run the playbook**

Confirm with the user before running — this SSHes into and reconfigures a real EC2 instance.

```bash
cd "/home/latnook/Documents/Voteball/ansible-project"
ansible-playbook site-k3s.yml
```
Expected: `PLAY RECAP` shows `failed=0`.

- [ ] **Step 3: Verify pods and services**

```bash
APP_IP=$(cd "/home/latnook/Documents/Voteball/terraform" && terraform output -raw app_public_ip)
ssh -i "/home/latnook/Documents/Voteball/Voteball-EC2-pem.pem" ec2-user@$APP_IP "
  sudo kubectl get nodes
  sudo kubectl get pods -n voteball-app
  sudo kubectl get deployments -n voteball-app
  sudo kubectl get services -n voteball-app
"
```
Expected: 5 pods Running (2 backend, 2 frontend, 1 worker), all Deployments Available.

- [ ] **Step 4: Verify the health endpoint and TLS**

```bash
curl -s https://voteball.latnook.com/api/health
```
Expected: `{"status": "ok"}` over valid HTTPS.

- [ ] **Step 5: Full manual vote + results flow**

Open `https://voteball.latnook.com` in a browser. Submit a vote (pick a league, optionally a club, a previous-vote choice, and either "undecided" or at least one upcoming party). Confirm redirect to `results.html` and that the submitted vote's league/club shows at least one bar once the worker's next 30-second cycle recomputes rollups (matches S3App's "worker picks it up on its next 30s poll" verification pattern).

- [ ] **Step 6: Verify the admin Knesset sync live**

```bash
curl -s -X POST https://voteball.latnook.com/api/admin/sync-previous-parties \
  -H "X-Admin-Secret: $(grep admin_secret /home/latnook/Documents/Voteball/ansible-project/inventories/voteball/group_vars/all/secrets.yml | awk '{print $2}')"
```
Expected: `{"synced": N}` with `N` matching the current Knesset's faction count; `GET /api/options` afterward shows real party names under `previous_parties`.

- [ ] **Step 7: Confirm SNS milestone alert code path**

Not practical to reach 100 real votes for a live test — instead, confirm the SNS topic subscription is live (check for the confirmation email sent when Task 2's `terraform apply` created `aws_sns_topic_subscription.email`, per S3App's existing convention of one-time manual email confirmation), and rely on Task 13's `test_check_and_notify_publishes_and_updates_state` as the actual correctness check for the alert logic itself.

- [ ] **Step 8: Final commit**

```bash
cd "/home/latnook/Documents/Voteball"
git add -A
git commit -m "Verified end-to-end deployment on voteball.latnook.com" --allow-empty
git push
```
