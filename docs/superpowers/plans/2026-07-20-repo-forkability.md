# Repo Cleanup and Forkability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repo a clean, forkable project: delete the retired stack, move app source to `services/`, and remove every hardcoded AWS account, domain and region from code.

**Architecture:** Identity resolves from exactly two places — `terraform/voteball.tfvars` before Terraform exists, and `terraform output` after. `scripts/lib/config.sh` is the only thing that reads them; every other script sources it.

**Tech Stack:** Terraform (AWS ~> 5.0), Helm 3, bash, python3, Docker, GitHub Actions.

Spec: `docs/superpowers/specs/2026-07-20-repo-forkability-design.md`

## Global Constraints

- No application behaviour changes — packaging, layout and configuration only.
- AWS is torn down; verification is local (`docker build`, pytest, `helm template`, `terraform validate`).
- `terraform fmt -recursive` before committing any `.tf` change.
- Commit and push per task (repo standing instruction).
- Preserve `docs/superpowers/plans` and `specs` — engineering history, deliberately kept.
- Use `git mv` for moves so history follows the files.

---

## File Structure (after)

```
services/{backend,worker,frontend,backup}/   app source, one Docker build context each
charts/voteball/                             Helm chart (unchanged location)
terraform/                               the only Terraform stack
scripts/                                     deploy.sh, destroy.sh, + lib/config.sh
argocd/, docs/, .github/workflows/ci.yml
README.md, README.submission.md, CLAUDE.md, LICENSE
```

Gone: `terraform/`, `ansible-project/`, `docker/`, `k8s/`, `docs/plan.md`, `scripts/generate-inventory.sh`.

---

### Task 1: Delete dead weight + gitignore hygiene

**Files:** delete `terraform/`, `ansible-project/{ansible.cfg,site-k3s.yml,inventories,roles/{k3s,common,app-compose}}`, `k8s/`, `scripts/generate-inventory.sh`, `docs/plan.md`; modify `.gitignore`.

- [ ] **Step 1: Confirm nothing live references them**

```bash
git grep -ln "ansible-project/inventories\|site-k3s\|roles/k3s\|k8s/namespace\|generate-inventory" -- . ':!docs/' ':!CLAUDE.md'
```

Expected: no output (only docs/CLAUDE.md mention them, and both are rewritten later).

- [ ] **Step 2: Delete**

```bash
git rm -r -q terraform k8s scripts/generate-inventory.sh docs/plan.md
git rm -r -q ansible-project/ansible.cfg ansible-project/site-k3s.yml ansible-project/inventories
git rm -r -q ansible-project/roles/k3s ansible-project/roles/common ansible-project/roles/app-compose
git rm -r -q ansible-project/roles/frontend/templates
```

- [ ] **Step 3: Add the untracked-but-unignored dotfolders to `.gitignore`**

Append:

```
# Local agent/session state — never belongs in the repo.
.remember/
.claude/settings.local.json
```

- [ ] **Step 4: Verify and commit**

```bash
git status --short | head -40
bash -n scripts/*.sh && helm lint charts/voteball
git commit -q -m "Remove retired k3s stack, Ansible tree, and superseded plan doc" && git push -q
```

---

### Task 2: Move app source to `services/`

**Files:** move 4 trees; modify `.github/workflows/ci.yml`, `scripts/build-push-ecr.sh`.

- [ ] **Step 1: Move with history preserved**

```bash
mkdir -p services
git mv ansible-project/roles/backend/files/backend   services/backend
git mv ansible-project/roles/worker/files/worker     services/worker
git mv ansible-project/roles/frontend/files/nginx    services/frontend
git mv docker/backup                                 services/backup
rmdir -p ansible-project/roles/backend/files ansible-project/roles/worker/files \
         ansible-project/roles/frontend/files 2>/dev/null || true
rm -rf ansible-project docker
```

- [ ] **Step 2: Update the CI workflow**

In `.github/workflows/ci.yml`, replace the `paths:` block:

```yaml
    paths:
      - "services/**"
      - ".github/workflows/ci.yml"
```

and the build-context map:

```bash
          declare -A CTX=(
            [voteball-backend]=services/backend
            [voteball-worker]=services/worker
            [voteball-nginx]=services/frontend
            [voteball-backup]=services/backup
          )
```

- [ ] **Step 3: Update `scripts/build-push-ecr.sh`**

Replace the four `build_push` lines:

```bash
build_push voteball-backend services/backend
build_push voteball-worker  services/worker
build_push voteball-nginx   services/frontend
build_push voteball-backup  services/backup
```

- [ ] **Step 4: Prove the contexts still build**

```bash
for s in backend worker frontend backup; do
  docker build -q -t voteball-$s:test services/$s >/dev/null && echo "  $s OK" || echo "  $s FAILED"
done
```

Expected: all four `OK`.

- [ ] **Step 5: Prove the test suites still pass**

```bash
docker start voteball-test-db 2>/dev/null || \
  docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd services/backend && python -m pytest tests/ -q; cd ../..
cd services/worker  && python -m pytest tests/ -q; cd ../..
```

Expected: both suites pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -q -m "Move app source to services/ (out of the retired Ansible tree)" && git push -q
```

---

### Task 3: Central config + Terraform outputs

**Files:** create `scripts/lib/config.sh`; modify `terraform/outputs.tf`, `terraform/variables.tf`.

**Interfaces:** `config.sh` exports `REGION`, `CLUSTER`, `APP_DOMAIN`, `ZONE_NAME`, and provides `tf_out <name>`.

- [ ] **Step 1: Make the maintainer-specific variables required**

In `terraform/variables.tf`, remove the default from `app_domain`:

```hcl
variable "app_domain" {
  description = "Public FQDN for the app (e.g. voteball.example.com). Required — no default."
  type        = string
}
```

Add, next to it:

```hcl
variable "route53_zone_name" {
  description = "Existing Route53 hosted zone that app_domain sits in, with trailing dot (e.g. example.com.)."
  type        = string
}
```

Then point the zone data source at it — in whichever file declares `data "aws_route53_zone" "primary"`:

```hcl
data "aws_route53_zone" "primary" {
  name         = var.route53_zone_name
  private_zone = false
}
```

- [ ] **Step 2: Add the outputs a forker's scripts need**

Append to `terraform/outputs.tf`:

```hcl
output "ecr_registry" {
  description = "ECR registry host for this account/region (image.registry in the Helm chart)."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "app_domain" {
  description = "Public FQDN the app is served on (ingress.host in the Helm chart)."
  value       = var.app_domain
}
```

If `data "aws_caller_identity" "current"` is not already declared in the stack, add it to `providers.tf`.

- [ ] **Step 3: Create `scripts/lib/config.sh`**

```bash
#!/usr/bin/env bash
# Single source of truth for this deployment's identity. Sourced by every script in scripts/.
#
# Two phases, because find-latest-snapshot.sh runs BEFORE `terraform apply` exists:
#   pre-apply  -> parsed from terraform/voteball.tfvars (falling back to variables.tf defaults)
#   post-apply -> read from `terraform output` (account id, ECR registry)
#
# Nothing here is specific to one AWS account or domain: fork the repo, edit your tfvars, done.

TF_DIR="${TF_DIR:-terraform}"
TFVARS="${TFVARS:-$TF_DIR/voteball.tfvars}"

# Read `name = "value"` from the tfvars file; $2 is the fallback when unset.
tfvar() {
  local key="$1" fallback="${2:-}" val=""
  if [ -f "$TFVARS" ]; then
    val="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$TFVARS" | head -1)"
  fi
  printf '%s' "${val:-$fallback}"
}

REGION="$(tfvar aws_region il-central-1)"
CLUSTER="$(tfvar cluster_name voteball)"
APP_DOMAIN="$(tfvar app_domain)"
ZONE_NAME="$(tfvar route53_zone_name)"

# Post-apply values. Fails loudly rather than returning an empty string that silently builds a
# malformed ECR URL or ARN.
tf_out() {
  local name="$1"
  if ! terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null; then
    echo "ERROR: Terraform output '${name}' unavailable — has the stack been applied?" >&2
    return 1
  fi
}

require_config() {
  local missing=0
  [ -n "$APP_DOMAIN" ] || { echo "ERROR: app_domain not set in $TFVARS" >&2; missing=1; }
  [ -n "$ZONE_NAME" ]  || { echo "ERROR: route53_zone_name not set in $TFVARS" >&2; missing=1; }
  [ "$missing" = "0" ] || { echo "See terraform/voteball.tfvars.example" >&2; exit 1; }
}
```

- [ ] **Step 4: Validate**

```bash
terraform -chdir=terraform fmt -recursive && terraform -chdir=terraform validate
bash -n scripts/lib/config.sh && echo "config.sh parses"
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -q -m "Add scripts/lib/config.sh and ecr_registry/app_domain outputs; require app_domain + route53_zone_name" && git push -q
```

---

### Task 4: De-hardcode the scripts and the chart

**Files:** modify `scripts/{build-push-ecr,find-latest-snapshot,cleanup-stale-dns,deploy,destroy,sync-values-from-tf}.sh`, `charts/voteball/values.yaml`, `scripts/tests/test-sync-values.sh`, `.github/workflows/ci.yml`.

- [ ] **Step 1: Source config.sh in every script**

In each of the six scripts, immediately after the `cd` to repo root, add:

```bash
# shellcheck source=lib/config.sh
. scripts/lib/config.sh
```

Then delete each script's own `REGION=`/`ACCOUNT=`/`CLUSTER=`/`ZONE_NAME=`/`HOST=`/`OWNER=` literals and use
`$REGION`, `$CLUSTER`, `$APP_DOMAIN`, `$ZONE_NAME` instead. In `build-push-ecr.sh` replace the
hardcoded `REGISTRY=` with `REGISTRY="$(tf_out ecr_registry)"`. In `cleanup-stale-dns.sh` use
`OWNER="$CLUSTER"` and `HOST="${APP_DOMAIN}."`.

- [ ] **Step 2: Add the two new managed fields to `sync-values-from-tf.sh`**

Add to the `managed` dict:

```python
    ("image",   "registry"):      os.environ["REGISTRY"],
    ("ingress", "host"):          os.environ["APP_DOMAIN_V"],
```

and export them alongside the existing values:

```bash
REGISTRY="$(tf_output ecr_registry)"
APP_DOMAIN_V="$(tf_output app_domain)"
```

adding `REGISTRY` and `APP_DOMAIN_V` to the `python3` invocation's environment.

Note `image.registry` has no quotes in `values.yaml` today; requote it so the existing `kv_re` matches.

- [ ] **Step 3: Extend the test for the two new fields**

In `scripts/tests/test-sync-values.sh`: add `registry: "old.example.com"` under `image:` and keep
`host: "old.example.com"` under `ingress:` in the fixture; export
`SYNC_STUB_ecr_registry="new.example.com"` and `SYNC_STUB_app_domain="new.example.com"`; assert both
are rewritten.

- [ ] **Step 4: Parameterise CI**

In `.github/workflows/ci.yml`:

```yaml
    env:
      REGION: ${{ vars.AWS_REGION }}
      REGISTRY: ${{ vars.ECR_REGISTRY }}
```

- [ ] **Step 5: Verify no identity remains in code**

```bash
./scripts/tests/test-sync-values.sh
git grep -n "590183895228\|latnook\.com" -- scripts charts .github terraform | grep -v example
```

Expected: test passes; the grep returns **nothing**.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -q -m "Remove hardcoded account/domain/region from scripts, chart and CI" && git push -q
```

---

### Task 5: Secrets without Ansible

**Files:** rewrite `scripts/seed-eks-secret.sh`.

- [ ] **Step 1: Rewrite**

```bash
#!/usr/bin/env bash
# Seed the app's credentials into AWS Secrets Manager (<cluster>/app-secret).
#
# Values come from the environment, or are prompted for (never echoed, never written to disk):
#   DB_PASS         must match the RDS master password (db_password in your tfvars)
#   ADMIN_USERNAME  admin login for /admin.html
#   ADMIN_PASSWORD  admin password (hashed here; the plaintext never leaves this process)
#
# ADMIN_SESSION_SECRET is generated. Rotating it invalidates all outstanding admin tokens.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh
. scripts/lib/config.sh

ask() {  # ask VAR "prompt"
  local var="$1" prompt="$2" val="${!1:-}"
  if [ -z "$val" ]; then read -rsp "$prompt: " val && echo >&2; fi
  [ -n "$val" ] || { echo "ERROR: $var must not be empty." >&2; exit 1; }
  printf '%s' "$val"
}

DB_PASS="$(ask DB_PASS "Database password (db_password from your tfvars)")"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="$(ask ADMIN_PASSWORD "Admin password for ${ADMIN_USERNAME}")"
ADMIN_SESSION_SECRET="$(openssl rand -hex 32)"

DB_PASS="$DB_PASS" ADMIN_USERNAME="$ADMIN_USERNAME" ADMIN_PASSWORD="$ADMIN_PASSWORD" \
ADMIN_SESSION_SECRET="$ADMIN_SESSION_SECRET" SECRET_ID="${CLUSTER}/app-secret" REGION="$REGION" \
python3 - <<'PY'
import json, os, subprocess, sys
try:
    from werkzeug.security import generate_password_hash
except ImportError:
    sys.exit("ERROR: pip install werkzeug (or run inside services/backend/.venv)")

secret = {
    "DB_USER": os.environ.get("DB_USER", "postgres"),
    "DB_PASS": os.environ["DB_PASS"],
    "ADMIN_USERNAME": os.environ["ADMIN_USERNAME"],
    "ADMIN_PASSWORD_HASH": generate_password_hash(os.environ["ADMIN_PASSWORD"]),
    "ADMIN_SESSION_SECRET": os.environ["ADMIN_SESSION_SECRET"],
}
subprocess.run(
    ["aws", "secretsmanager", "put-secret-value",
     "--secret-id", os.environ["SECRET_ID"], "--region", os.environ["REGION"],
     "--secret-string", json.dumps(secret)],
    check=True, stdout=subprocess.DEVNULL,
)
print(f"Done: seeded 5 values into {os.environ['SECRET_ID']}. Nothing was printed or written to disk.")
PY
```

- [ ] **Step 2: Verify it refuses empties and never prints secrets**

```bash
bash -n scripts/seed-eks-secret.sh
DB_PASS="" ADMIN_PASSWORD=x ./scripts/seed-eks-secret.sh </dev/null 2>&1 | grep -q "must not be empty" \
  && echo "empty-input guard OK"
grep -c 'echo "\$DB_PASS"\|echo "\$ADMIN_PASSWORD"' scripts/seed-eks-secret.sh   # expect 0
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -q -m "seed-eks-secret.sh: take credentials from env/prompt instead of ansible-vault" && git push -q
```

---

### Task 6: Make the from-zero database path work

**Files:** modify `terraform/database.tf`, `terraform/variables.tf`.

- [ ] **Step 1: Add the variables**

```hcl
variable "db_username" {
  description = "RDS master username. Only applied when creating a fresh database (ignored on snapshot restore)."
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "RDS master password. Also RESETS the master password when restoring from a snapshot, so it always matches the DB_PASS seeded into Secrets Manager."
  type        = string
  sensitive   = true
}
```

- [ ] **Step 2: Use them**

In `aws_db_instance.app`, add:

```hcl
  username = var.db_username
  password = var.db_password
```

and extend the existing `lifecycle` block (created in the deployment-hardening plan) with:

```hcl
  lifecycle {
    # username cannot change on a snapshot restore; without this Terraform proposes a replacement.
    ignore_changes = [username]
  }
```

- [ ] **Step 3: Validate**

```bash
terraform -chdir=terraform fmt -recursive && terraform -chdir=terraform validate
```

Expected: valid. (A real plan needs credentials; correctness here is confirmed on the next deploy.)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -q -m "Support creating the database from scratch (db_username/db_password)" && git push -q
```

---

### Task 7: README, LICENSE, tfvars example

**Files:** modify `README.md`, `terraform/voteball.tfvars.example`, `docs/deploy.md`, `CLAUDE.md`; create `LICENSE`.

- [ ] **Step 1: Rewrite `voteball.tfvars.example`** with every required variable, commented:

```hcl
# Copy to voteball.tfvars and fill in. This file is the only place your identity lives.
aws_region         = "il-central-1"           # any region you have quota in
cluster_name       = "voteball"               # name prefix for every AWS resource
app_domain         = "voteball.example.com"   # REQUIRED: the public FQDN
route53_zone_name  = "example.com."           # REQUIRED: existing hosted zone, trailing dot
notification_email = "you@example.com"        # SNS milestone alerts
db_password        = "change-me"              # RDS master password
```

- [ ] **Step 2: Add a Quickstart to `README.md`** covering: prerequisites, the five tfvars values, the
three secret env vars, `./scripts/deploy.sh`, `./scripts/destroy.sh`, and the three GitHub repo
variables CI needs (`AWS_ROLE_ARN`, `AWS_REGION`, `ECR_REGISTRY`).

- [ ] **Step 3: Add MIT `LICENSE`** (copyright holder: Ariel Palatnik, 2026).

- [ ] **Step 4: Update `CLAUDE.md` and `docs/deploy.md`** for the new paths (`services/*`), the new
secret flow, and note the benign ArgoCD CRD `resource-policy: keep` warning at teardown.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -q -m "Add Quickstart, LICENSE and a complete tfvars example" && git push -q
```

---

### Task 8: Full local verification

- [ ] **Step 1: Run everything**

```bash
for s in backend worker frontend backup; do docker build -q -t voteball-$s:test services/$s >/dev/null && echo "  build $s OK"; done
(cd services/backend && python -m pytest tests/ -q | tail -1)
(cd services/worker  && python -m pytest tests/ -q | tail -1)
helm lint charts/voteball && helm template voteball charts/voteball -n devops-app >/dev/null && echo "  helm OK"
terraform -chdir=terraform fmt -check -recursive && terraform -chdir=terraform validate
./scripts/tests/test-sync-values.sh | tail -1
for f in scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh; do bash -n "$f" || echo "SYNTAX FAIL $f"; done
```

- [ ] **Step 2: Assert no identity leaked into code**

```bash
helm template voteball charts/voteball -n devops-app | grep -c "590183895228\|latnook" # expect 0
git grep -n "590183895228\|latnook\.com" -- scripts charts .github terraform services | grep -v example
```

Expected: `0`, and the grep silent.

- [ ] **Step 3: Commit any residue and report**

---

## Self-Review

**Spec coverage:** §1→T1, §2→T2, §3→T3+T4, §4→T5, §5→T6, §6→T7, Verification→T8. No gaps.

**Placeholder scan:** none — every step carries exact commands or full file content.

**Type consistency:** `config.sh` exports `REGION`/`CLUSTER`/`APP_DOMAIN`/`ZONE_NAME` and the helpers
`tfvar`/`tf_out`/`require_config`; those names are used identically in Tasks 4 and 5. The
`SYNC_STUB_<output>` convention from the hardening plan is preserved for the two new fields.

**Known risk carried forward:** Task 6 cannot be verified without an apply; flagged in the spec and to
be re-checked on the next deploy.
