# Deployment Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the EKS `terraform apply` → `helm` → `terraform destroy` cycle repeatable without hand-editing files or hitting ordering races.

**Architecture:** Eliminate drift where possible (disable the ALB webhook we don't need; derive every environment-specific value from Terraform outputs), and wrap the remaining ordering constraints in two orchestrator scripts that stop before billed/destructive Terraform operations.

**Tech Stack:** Terraform (AWS ~> 5.0, Helm ~> 2.17, Kubernetes ~> 2.31, + new `hashicorp/time`), Helm 3, bash, python3, AWS CLI v2, kubectl.

Spec: `docs/superpowers/specs/2026-07-20-deployment-hardening-design.md`

## Global Constraints

- Region `il-central-1`; account `590183895228`; cluster/prefix `voteball`; namespace `devops-app`.
- Terraform commands always take `-var-file=voteball-eks.tfvars` (gitignored).
- `terraform fmt -recursive` before committing any `.tf` change.
- Never run `terraform apply`/`destroy` unattended — orchestrators must stop for confirmation.
- No new tool dependencies beyond what `docs/deploy.md` already requires (terraform, aws, kubectl, helm, docker, python3, ansible-vault).
- Commit and push as work is completed (repo standing instruction in CLAUDE.md).
- `charts/voteball/values.yaml` stays committed to git — ArgoCD reads it from `master`.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `scripts/sync-values-from-tf.sh` | Sole writer of env-specific fields in `values.yaml`; `--check` preflight | Create |
| `scripts/deploy.sh` | Ordered deploy sequence, stops before `terraform apply` | Create |
| `scripts/destroy.sh` | Ordered teardown, stops before `terraform destroy` | Create |
| `scripts/find-latest-snapshot.sh` | Resolve newest snapshot → `terraform-eks/snapshot.auto.tfvars` | Rewrite |
| `terraform-eks/addon-alb.tf` | Disable service-mutator webhook | Modify |
| `terraform-eks/addon-external-dns.tf` | `policy=sync` | Modify |
| `terraform-eks/database.tf` | Final snapshot on destroy | Modify |
| `terraform-eks/variables.tf` | `db_snapshot_identifier` default → `null` | Modify |
| `terraform-eks/versions.tf` | Add `hashicorp/time` provider | Modify |
| `docs/deploy.md` | Runbook rewritten around the two orchestrators | Rewrite |
| `CLAUDE.md` | Deployment section reflects new scripts | Modify |

**Values owned by `sync-values-from-tf.sh`** (note `roleArn` appears under **both** `backup` and `worker` — section-aware replacement is mandatory):

| Section | Key | Terraform output |
|---|---|---|
| `image` | `tag` | *(git SHA, not TF)* |
| `config` | `DB_HOST` | `rds_endpoint` |
| `config` | `S3_BUCKET` | `s3_bucket` |
| `ingress` | `certificateArn` | `acm_certificate_arn` |
| `backup` | `roleArn` | `backup_role_arn` |
| `worker` | `roleArn` | `worker_role_arn` |

---

### Task 1: `sync-values-from-tf.sh`

**Files:**
- Create: `scripts/sync-values-from-tf.sh`
- Test: `scripts/tests/test-sync-values.sh`

**Interfaces:**
- Consumes: Terraform outputs `rds_endpoint`, `acm_certificate_arn`, `s3_bucket`, `backup_role_arn`, `worker_role_arn`.
- Produces: `scripts/sync-values-from-tf.sh` supporting `--check` (exit 1 on drift, no write), `--tag <sha>` (override git SHA), and `--values <path>` (override target file, used by tests).

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test-sync-values.sh`:

```bash
#!/usr/bin/env bash
# Tests the section-aware rewriter against a fixture, with NO AWS/Terraform access.
# Terraform lookups are stubbed via the SYNC_STUB_* env vars the script honours.
set -euo pipefail
cd "$(dirname "$0")/../.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/values.yaml"

cat > "$FIXTURE" <<'EOF'
image:
  registry: 590183895228.dkr.ecr.il-central-1.amazonaws.com
  tag: "OLDTAG" # git-SHA tag
  pullPolicy: IfNotPresent

config:
  DB_HOST: "old-db.example.com"
  DB_NAME: "postgres"
  S3_BUCKET: "old-bucket"

ingress:
  host: "voteball.latnook.com"
  certificateArn: "arn:aws:acm:il-central-1:590183895228:certificate/OLD"

backup:
  roleArn: "arn:aws:iam::590183895228:role/OLD-backup"
  schedule: "0 2 * * *"

worker:
  replicas: 1
  roleArn: "arn:aws:iam::590183895228:role/OLD-worker"
EOF

export SYNC_STUB_rds_endpoint="new-db.example.com"
export SYNC_STUB_acm_certificate_arn="arn:aws:acm:il-central-1:590183895228:certificate/NEW"
export SYNC_STUB_s3_bucket="new-bucket"
export SYNC_STUB_backup_role_arn="arn:aws:iam::590183895228:role/NEW-backup"
export SYNC_STUB_worker_role_arn="arn:aws:iam::590183895228:role/NEW-worker"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- 1. --check on a drifted file must exit non-zero and NOT write ---
BEFORE="$(cat "$FIXTURE")"
if ./scripts/sync-values-from-tf.sh --check --tag NEWTAG --values "$FIXTURE"; then
  fail "--check should exit non-zero when the file has drifted"
fi
[ "$BEFORE" = "$(cat "$FIXTURE")" ] || fail "--check must not modify the file"

# --- 2. a real run rewrites every managed value ---
./scripts/sync-values-from-tf.sh --tag NEWTAG --values "$FIXTURE"

grep -q 'tag: "NEWTAG"'                  "$FIXTURE" || fail "image.tag not updated"
grep -q 'DB_HOST: "new-db.example.com"'  "$FIXTURE" || fail "config.DB_HOST not updated"
grep -q 'S3_BUCKET: "new-bucket"'        "$FIXTURE" || fail "config.S3_BUCKET not updated"
grep -q 'certificateArn: ".*NEW"'        "$FIXTURE" || fail "ingress.certificateArn not updated"

# --- 3. the two same-named roleArn keys must NOT be cross-assigned ---
grep -q 'roleArn: "arn:aws:iam::590183895228:role/NEW-backup"' "$FIXTURE" || fail "backup.roleArn wrong"
grep -q 'roleArn: "arn:aws:iam::590183895228:role/NEW-worker"' "$FIXTURE" || fail "worker.roleArn wrong"
[ "$(grep -c 'NEW-backup' "$FIXTURE")" -eq 1 ] || fail "backup role leaked into another section"
[ "$(grep -c 'NEW-worker' "$FIXTURE")" -eq 1 ] || fail "worker role leaked into another section"

# --- 4. unmanaged keys and comments survive ---
grep -q 'DB_NAME: "postgres"'   "$FIXTURE" || fail "unmanaged key DB_NAME was clobbered"
grep -q 'schedule: "0 2 \* \* \*"' "$FIXTURE" || fail "unmanaged key schedule was clobbered"
grep -q '# git-SHA tag'         "$FIXTURE" || fail "trailing comment was lost"

# --- 5. --check on a synced file exits 0 ---
./scripts/sync-values-from-tf.sh --check --tag NEWTAG --values "$FIXTURE" \
  || fail "--check should exit 0 when the file is already in sync"

echo "PASS: all sync-values assertions"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x scripts/tests/test-sync-values.sh
./scripts/tests/test-sync-values.sh
```

Expected: FAIL — `./scripts/sync-values-from-tf.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

Create `scripts/sync-values-from-tf.sh`:

```bash
#!/usr/bin/env bash
# Sole writer of the environment-specific fields in charts/voteball/values.yaml.
#
# Every value below changes when the stack is rebuilt (new RDS instance, new ACM cert, new IAM roles),
# which is why hand-copying them kept breaking deploys. Run this instead of editing the file.
#
#   ./scripts/sync-values-from-tf.sh              # write current values (tag = git HEAD)
#   ./scripts/sync-values-from-tf.sh --check      # exit 1 if drifted, write nothing (preflight)
#   ./scripts/sync-values-from-tf.sh --tag abc123 # pin a specific image tag
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

TF_DIR="terraform-eks"
VALUES="charts/voteball/values.yaml"
CHECK_ONLY=0
TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  CHECK_ONLY=1; shift ;;
    --tag)    TAG="$2"; shift 2 ;;
    --values) VALUES="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TAG" ] || TAG="$(git rev-parse --short HEAD)"

# Read one Terraform output. SYNC_STUB_<name> overrides it, so the test suite can run with no AWS
# credentials and no built stack.
tf_output() {
  local name="$1" stub
  stub="SYNC_STUB_${name}"
  if [ -n "${!stub:-}" ]; then
    printf '%s' "${!stub}"
    return 0
  fi
  if ! terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null; then
    echo "ERROR: could not read Terraform output '${name}'." >&2
    echo "Is the stack applied? Try: terraform -chdir=${TF_DIR} output" >&2
    exit 1
  fi
}

DB_HOST="$(tf_output rds_endpoint)"
CERT_ARN="$(tf_output acm_certificate_arn)"
S3_BUCKET="$(tf_output s3_bucket)"
BACKUP_ROLE="$(tf_output backup_role_arn)"
WORKER_ROLE="$(tf_output worker_role_arn)"

# Section-aware rewrite. `roleArn` exists under BOTH `backup:` and `worker:` at the same indent, so a
# plain anchored sed would assign the same ARN to both. Track the current top-level section instead.
# Line-oriented (not a YAML round-trip) so comments and formatting survive byte-for-byte.
CHECK_ONLY="$CHECK_ONLY" VALUES="$VALUES" \
TAG="$TAG" DB_HOST="$DB_HOST" CERT_ARN="$CERT_ARN" S3_BUCKET="$S3_BUCKET" \
BACKUP_ROLE="$BACKUP_ROLE" WORKER_ROLE="$WORKER_ROLE" \
python3 <<'PY'
import os, re, sys

values_path = os.environ["VALUES"]
check_only  = os.environ["CHECK_ONLY"] == "1"

managed = {
    ("image",   "tag"):            os.environ["TAG"],
    ("config",  "DB_HOST"):        os.environ["DB_HOST"],
    ("config",  "S3_BUCKET"):      os.environ["S3_BUCKET"],
    ("ingress", "certificateArn"): os.environ["CERT_ARN"],
    ("backup",  "roleArn"):        os.environ["BACKUP_ROLE"],
    ("worker",  "roleArn"):        os.environ["WORKER_ROLE"],
}

top_re = re.compile(r'^([A-Za-z_][\w-]*):\s*$')
kv_re  = re.compile(r'^(  )([A-Za-z_][\w-]*): (")([^"]*)(")(.*)$')

with open(values_path) as fh:
    lines = fh.read().splitlines(keepends=True)

section = None
changed = []
out = []

for line in lines:
    m_top = top_re.match(line)
    if m_top:
        section = m_top.group(1)
        out.append(line)
        continue

    m_kv = kv_re.match(line)
    if m_kv and (section, m_kv.group(2)) in managed:
        want = managed[(section, m_kv.group(2))]
        have = m_kv.group(4)
        if have != want:
            changed.append(f"  {section}.{m_kv.group(2)}: {have} -> {want}")
            line = f"{m_kv.group(1)}{m_kv.group(2)}: \"{want}\"{m_kv.group(6)}\n"
    out.append(line)

found = set()
section = None
for line in lines:
    m_top = top_re.match(line)
    if m_top:
        section = m_top.group(1)
        continue
    m_kv = kv_re.match(line)
    if m_kv and (section, m_kv.group(2)) in managed:
        found.add((section, m_kv.group(2)))

missing = set(managed) - found
if missing:
    for s, k in sorted(missing):
        print(f"ERROR: expected key {s}.{k} not found in {values_path}", file=sys.stderr)
    print("The values file layout changed; update scripts/sync-values-from-tf.sh.", file=sys.stderr)
    sys.exit(2)

if check_only:
    if changed:
        print("values.yaml is OUT OF SYNC with the live stack:")
        print("\n".join(changed))
        print("\nRun: ./scripts/sync-values-from-tf.sh")
        sys.exit(1)
    print(f"values.yaml is in sync with {os.environ.get('TF_DIR', 'terraform-eks')}.")
    sys.exit(0)

if not changed:
    print("values.yaml already in sync; nothing to write.")
    sys.exit(0)

with open(values_path, "w") as fh:
    fh.writelines(out)

print("Updated values.yaml:")
print("\n".join(changed))
PY
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/sync-values-from-tf.sh
bash -n scripts/sync-values-from-tf.sh
./scripts/tests/test-sync-values.sh
```

Expected: `PASS: all sync-values assertions`

- [ ] **Step 5: Verify against the real stack (read-only)**

```bash
./scripts/sync-values-from-tf.sh --check
```

Expected: exit 0 with "values.yaml is in sync" (the live values were corrected in `b9779cf`). If it reports drift, the drift is real — inspect before writing.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-values-from-tf.sh scripts/tests/test-sync-values.sh
git commit -m "Add sync-values-from-tf.sh: derive values.yaml env fields from Terraform outputs"
git push
```

---

### Task 2: Disable the ALB service-mutator webhook

**Files:**
- Modify: `terraform-eks/addon-alb.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: no interface; removes the cluster-wide Service admission hook that other add-ons raced.

- [ ] **Step 1: Confirm no Service of type LoadBalancer exists**

```bash
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

Expected: empty output. If anything is listed, STOP — disabling the webhook would change its behaviour, and this task needs rethinking.

- [ ] **Step 2: Add the chart value**

In `terraform-eks/addon-alb.tf`, append inside `resource "helm_release" "aws_load_balancer_controller"`, after the existing `serviceAccount.annotations...` block:

```hcl
  # The service mutator webhook exists ONLY to make this controller the default for new Services of
  # type LoadBalancer (chart docs, values.yaml `enableServiceMutatorWebhook`). Voteball routes solely
  # via Ingress->ALB and has zero type=LoadBalancer Services, so the webhook adds nothing -- but it
  # intercepts EVERY Service creation cluster-wide with failurePolicy:Fail. That races add-ons that
  # create Services before this controller's pods are Ready:
  #   "no endpoints available for service aws-load-balancer-webhook-service"
  # (hit by amazon-cloudwatch-observability 2026-07-19 and kube-prometheus-stack 2026-07-20).
  # Disabling it removes the race for every current and future add-on.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }
```

- [ ] **Step 3: Validate**

```bash
terraform -chdir=terraform-eks fmt -recursive
terraform -chdir=terraform-eks validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add terraform-eks/addon-alb.tf
git commit -m "terraform-eks: disable ALB service-mutator webhook (root fix for add-on race)"
git push
```

---

### Task 3: Snapshot lifecycle

**Files:**
- Rewrite: `scripts/find-latest-snapshot.sh`
- Modify: `terraform-eks/database.tf`, `terraform-eks/variables.tf`, `terraform-eks/versions.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `terraform-eks/snapshot.auto.tfvars` containing `db_snapshot_identifier = "<id>"` or `db_snapshot_identifier = null`. Terraform auto-loads `*.auto.tfvars`.

- [ ] **Step 1: Confirm the gitignore covers the new auto.tfvars path**

```bash
grep -n "auto.tfvars" .gitignore || echo "NOT IGNORED"
```

If it prints `NOT IGNORED` or only matches `terraform/`, add this line to `.gitignore`:

```
terraform-eks/snapshot.auto.tfvars
```

- [ ] **Step 2: Rewrite the snapshot finder**

Replace the entire contents of `scripts/find-latest-snapshot.sh`:

```bash
#!/usr/bin/env bash
# Usage: ./scripts/find-latest-snapshot.sh
# Picks the newest manual RDS snapshot from EITHER voteball lineage (the retired k3s `voteball-db`
# or the current `voteball-eks-db`) and writes it to terraform-eks/snapshot.auto.tfvars, which
# Terraform auto-loads. Run before `terraform apply`; scripts/deploy.sh does this for you.
#
# Writes `db_snapshot_identifier = null` when no snapshot exists, so a first-ever deploy creates an
# empty DB instead of hard-failing on a pinned identifier that is no longer there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform-eks"
AUTO_TFVARS="$TF_DIR/snapshot.auto.tfvars"
REGION="il-central-1"

# Distinguish "the API call succeeded and found zero snapshots" (safe: no prior snapshot) from "the
# API call itself failed" (expired SSO token, wrong profile, no network, throttling). The latter must
# abort loudly rather than silently falling through to "fresh empty DB" -- that is exactly the
# accidental-data-loss outcome this script exists to prevent. A failed call also leaves any existing
# snapshot.auto.tfvars untouched rather than deleting a possibly-still-correct one.
#
# Both lineages are searched: the k3s-era `voteball-db` holds the original vote history, and
# `voteball-eks-db` holds every final snapshot taken since. Newest SnapshotCreateTime wins.
if ! SNAPSHOT_ID=$(aws rds describe-db-snapshots \
  --snapshot-type manual \
  --region "$REGION" \
  --query 'sort_by(DBSnapshots[?starts_with(DBInstanceIdentifier, `voteball`)], &SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text); then
  echo "ERROR: aws rds describe-db-snapshots failed -- check AWS credentials/network." >&2
  echo "Refusing to guess whether a snapshot exists; $AUTO_TFVARS left untouched." >&2
  exit 1
fi

if [ "$SNAPSHOT_ID" = "None" ] || [ -z "$SNAPSHOT_ID" ]; then
  echo "db_snapshot_identifier = null" > "$AUTO_TFVARS"
  echo "No prior snapshot found — next apply creates a fresh, empty database."
else
  echo "db_snapshot_identifier = \"$SNAPSHOT_ID\"" > "$AUTO_TFVARS"
  echo "Found $SNAPSHOT_ID — next apply will restore from it."
  echo "(To force a fresh empty DB instead, put 'db_snapshot_identifier = null' in $AUTO_TFVARS.)"
fi
```

- [ ] **Step 3: Run it and verify the output**

```bash
bash -n scripts/find-latest-snapshot.sh
./scripts/find-latest-snapshot.sh
cat terraform-eks/snapshot.auto.tfvars
```

Expected: `Found voteball-db-final-20260719175321 — next apply will restore from it.` and the file contains that identifier. (That is currently the only manual snapshot in the account.)

- [ ] **Step 4: Add the `time` provider**

In `terraform-eks/versions.tf`, add inside `required_providers`:

```hcl
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12" # time_static: stable timestamp for the RDS final-snapshot name
    }
```

- [ ] **Step 5: Take a final snapshot on destroy**

In `terraform-eks/database.tf`, add above `resource "aws_db_instance" "app"`:

```hcl
# Fixed at apply time so the final-snapshot name below is stable across plans (a bare timestamp()
# would re-evaluate every plan and show a perpetual diff). A destroy+apply cycle recreates this
# resource, so each cycle gets a distinct snapshot name and they never collide.
resource "time_static" "deploy" {}
```

Then in `resource "aws_db_instance" "app"`, replace this line:

```hcl
  skip_final_snapshot = true
```

with:

```hcl
  # Every destroy leaves a restore point, so destroy->apply preserves votes and the stack no longer
  # depends on one hand-pinned snapshot surviving. find-latest-snapshot.sh picks the newest one up.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster_name}-eks-db-final-${formatdate("YYYYMMDDhhmmss", time_static.deploy.rfc3339)}"
```

And add a `lifecycle` block at the end of the same resource (before its closing brace):

```hcl
  lifecycle {
    # The name embeds a creation-time timestamp; without this, replacing time_static would show a diff.
    ignore_changes = [final_snapshot_identifier]
  }
```

Also update the trade-off comment in that resource — replace the line:

```hcl
  #   skip_final_snapshot=true    -> this is a throwaway copy; the k3s snapshot is the source of truth
```

with:

```hcl
  #   final snapshot on destroy   -> votes survive a destroy/rebuild cycle (see skip_final_snapshot below)
```

- [ ] **Step 6: Default the snapshot variable to null**

In `terraform-eks/variables.tf`, in `variable "db_snapshot_identifier"`, replace:

```hcl
  default     = "voteball-db-final-20260719175321"
```

with:

```hcl
  # null, NOT a pinned identifier: scripts/find-latest-snapshot.sh writes the real value into
  # terraform-eks/snapshot.auto.tfvars before every apply. A hardcoded default silently hard-fails
  # ("DBSnapshot not found") the moment that one snapshot is pruned.
  default = null
```

- [ ] **Step 7: Validate**

```bash
terraform -chdir=terraform-eks init -upgrade
terraform -chdir=terraform-eks fmt -recursive
terraform -chdir=terraform-eks validate
```

Expected: provider `hashicorp/time` installed, then `Success! The configuration is valid.`

- [ ] **Step 8: Commit**

```bash
git add scripts/find-latest-snapshot.sh terraform-eks/database.tf terraform-eks/variables.tf terraform-eks/versions.tf terraform-eks/.terraform.lock.hcl .gitignore
git commit -m "Make DB snapshot lifecycle self-sustaining (final snapshot on destroy, both lineages)"
git push
```

---

### Task 4: external-dns clean teardown

**Files:**
- Modify: `terraform-eks/addon-external-dns.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: external-dns now deletes the records it owns when the Ingress is removed — relied on by `destroy.sh` (Task 5).

- [ ] **Step 1: Record the current zone state as a safety baseline**

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z00371679I0OE09A8HIG \
  --output json > /tmp/claude-1000/-home-latnook-Documents-Voteball/1507f3c8-a339-4ebe-b5c0-9278df5f94e8/scratchpad/route53-baseline.json
grep -c '"Name"' /tmp/claude-1000/-home-latnook-Documents-Voteball/1507f3c8-a339-4ebe-b5c0-9278df5f94e8/scratchpad/route53-baseline.json
```

Expected: a record count printed. Keep this file — Task 7 diffs against it to prove apex records survived.

- [ ] **Step 2: Switch the policy**

In `terraform-eks/addon-external-dns.tf`, replace:

```hcl
  set {
    name  = "policy"
    value = "upsert-only"
  }
```

with:

```hcl
  # sync (not upsert-only): on teardown the Ingress is deleted BEFORE terraform destroy, letting
  # external-dns remove the A/AAAA/TXT records it created. With upsert-only they survived, leaving
  # voteball.latnook.com resolving to a de-provisioned ALB until the next deploy.
  # Deletion is bounded by txtOwnerId + domainFilters below: external-dns only touches records whose
  # ownership TXT names this cluster, so apex latnook.com records are never eligible.
  set {
    name  = "policy"
    value = "sync"
  }
```

Also update the header comment on the `helm_release` — replace `policy=upsert-only so it never deletes records it didn't create;` with `policy=sync so teardown removes the records it created (ownership TXT gates what it may touch);`.

- [ ] **Step 3: Validate**

```bash
terraform -chdir=terraform-eks fmt -recursive
terraform -chdir=terraform-eks validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add terraform-eks/addon-external-dns.tf
git commit -m "terraform-eks: external-dns policy=sync so teardown removes its own DNS records"
git push
```

---

### Task 5: `deploy.sh` and `destroy.sh` orchestrators

**Files:**
- Create: `scripts/deploy.sh`, `scripts/destroy.sh`

**Interfaces:**
- Consumes: `find-latest-snapshot.sh`, `seed-eks-secret.sh`, `build-push-ecr.sh`, `sync-values-from-tf.sh` (Task 1), `argocd/voteball-application.yaml`.
- Produces: the two commands `docs/deploy.md` (Task 6) is written around.

- [ ] **Step 1: Write `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
# Full ordered deploy. Stops before `terraform apply` so you confirm the (billed) change yourself.
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

REGION="il-central-1"
CLUSTER="voteball"
TFVARS="voteball-eks.tfvars"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if [ ! -f "terraform-eks/$TFVARS" ]; then
  echo "ERROR: terraform-eks/$TFVARS is missing (see docs/deploy.md, One-time setup)." >&2
  exit 1
fi

step "1/8  Resolving the newest DB snapshot"
./scripts/find-latest-snapshot.sh

step "2/8  Building AWS infrastructure (Terraform will ask you to confirm)"
echo "This creates real, billed resources (~\$200/month while up)."
terraform -chdir=terraform-eks init -upgrade
terraform -chdir=terraform-eks apply -var-file="$TFVARS"

step "3/8  Seeding app credentials into Secrets Manager"
./scripts/seed-eks-secret.sh

step "4/8  Pointing kubectl at the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

step "5/8  Building and pushing container images"
./scripts/build-push-ecr.sh

step "6/8  Syncing values.yaml from Terraform outputs"
./scripts/sync-values-from-tf.sh

step "7/8  Installing the app"
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
kubectl rollout status deployment/backend  -n devops-app --timeout=300s
kubectl rollout status deployment/frontend -n devops-app --timeout=300s
kubectl rollout status deployment/worker   -n devops-app --timeout=300s

step "8/8  Bootstrapping ArgoCD (GitOps takes over from here)"
kubectl apply -f argocd/voteball-application.yaml

cat <<'EOF'

Deploy complete.

  If values.yaml changed in step 6, commit it -- ArgoCD syncs from master:
      git add charts/voteball/values.yaml && git commit -m "Deploy: sync values" && git push

  Verify:
      kubectl get pods -n devops-app
      curl -sf https://voteball.latnook.com/api/options | head -c 120

  DNS can take a minute to propagate after a rebuild.
EOF
```

- [ ] **Step 2: Write `scripts/destroy.sh`**

```bash
#!/usr/bin/env bash
# Full ordered teardown. Stops before `terraform destroy` so you confirm it yourself.
#
# Order matters and is the reason this script exists:
#   1. ArgoCD Application first  -- selfHeal:true would otherwise recreate everything we delete.
#   2. Ingress next              -- lets external-dns remove its DNS records and the ALB
#                                   de-provision. A leftover ALB's ENIs block VPC deletion.
#   3. Wait for the ALB to go    -- polling, because deletion is asynchronous.
#   4. terraform destroy last.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

REGION="il-central-1"
TFVARS="voteball-eks.tfvars"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "1/5  Removing the ArgoCD Application (stops selfHeal fighting the teardown)"
kubectl delete -f argocd/voteball-application.yaml --ignore-not-found

step "2/5  Removing the Ingress (releases the ALB and the DNS records)"
kubectl delete ingress voteball -n devops-app --ignore-not-found

step "3/5  Waiting for the ALB to de-provision (its ENIs block VPC deletion)"
for _ in $(seq 1 60); do
  remaining="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-devopsap-voteball')].LoadBalancerName" \
    --output text 2>/dev/null || echo "")"
  if [ -z "$remaining" ] || [ "$remaining" = "None" ]; then
    echo "ALB gone."
    break
  fi
  echo "  still present ($remaining) — waiting 10s"
  sleep 10
done

step "4/5  Uninstalling the Helm release"
helm uninstall voteball -n devops-app --ignore-not-found || true

step "5/5  Destroying AWS infrastructure (Terraform will ask you to confirm)"
terraform -chdir=terraform-eks destroy -var-file="$TFVARS"

cat <<'EOF'

Teardown complete. A final DB snapshot was taken -- the next deploy restores from it automatically.

  If destroy hung uninstalling a helm_release ("context deadline exceeded"), Helm cannot cleanly
  uninstall while the cluster is being deleted. Drop that release from state and re-run; it dies
  with the cluster anyway:
      terraform -chdir=terraform-eks state rm helm_release.<name>
      ./scripts/destroy.sh
EOF
```

- [ ] **Step 3: Syntax-check both**

```bash
chmod +x scripts/deploy.sh scripts/destroy.sh
bash -n scripts/deploy.sh
bash -n scripts/destroy.sh
```

Expected: no output from either (clean parse).

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy.sh scripts/destroy.sh
git commit -m "Add ordered deploy.sh/destroy.sh orchestrators (incl. missing ArgoCD bootstrap)"
git push
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/deploy.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: the scripts from Tasks 1, 3, 5.
- Produces: no code interface.

- [ ] **Step 1: Rewrite the "Put the site online" section of `docs/deploy.md`**

Replace the whole numbered 1–7 sequence with:

````markdown
**Everything, in order:**

```bash
./scripts/deploy.sh
```

It runs the whole sequence and **stops to ask you to confirm** before Terraform creates billed
resources. The steps it performs:

1. Find the newest database snapshot to restore from.
2. Build the AWS infrastructure (**asks you to type `yes`**).
3. Copy the app's passwords into AWS's secret vault (nothing secret is printed or stored in git).
4. Point `kubectl` at the new cluster.
5. Build the four container images and upload them.
6. Fill in `charts/voteball/values.yaml` from the Terraform outputs — the database address, the
   certificate, the bucket, and the IAM roles all change on every rebuild, so **never edit these by
   hand**.
7. Install the app and wait for it to come up.
8. Hand ongoing control to ArgoCD.

If step 6 changed `values.yaml`, commit it — ArgoCD deploys from `master`:

```bash
git add charts/voteball/values.yaml && git commit -m "Deploy: sync values" && git push
```

**Confirm the alert email:** check your inbox for an AWS confirmation link and click it, or the
milestone-alert emails won't arrive.

Give it a few minutes, then open **https://voteball.latnook.com**.

**Later, after changing app code:** just `git push` — CI rebuilds the images and ArgoCD deploys them.
To do it by hand instead, run `./scripts/deploy.sh` again.
````

- [ ] **Step 2: Replace the "Take it down" section of `docs/deploy.md`**

````markdown
## Take it down (stop paying)

```bash
./scripts/destroy.sh
```

It removes things in the order that actually works, and **asks you to confirm** before deleting the
infrastructure. Order matters:

1. **The ArgoCD app first** — otherwise ArgoCD notices the app disappearing and puts it straight back.
2. **The Ingress next** — this releases the load balancer and cleans up the DNS record. A leftover
   load balancer keeps network interfaces alive that block the network from being deleted.
3. **Wait** for the load balancer to actually disappear.
4. **Then** delete everything else.

A final database snapshot is taken automatically, so the next `./scripts/deploy.sh` restores your
votes. (This changed on 2026-07-20 — teardown used to discard them.)
````

- [ ] **Step 3: Add a troubleshooting entry to `docs/deploy.md`**

Under "If something breaks", add:

````markdown
- **The site can't be found right after a rebuild** → DNS. The record is recreated on deploy, but your
  computer may have cached the old answer. Check it works publicly first:
  `dig +short voteball.latnook.com @8.8.8.8` — if that returns addresses, flush your local cache
  (`sudo resolvectl flush-caches`) or try a private browser window.
- **`terraform destroy` hangs on a `helm_release`** ("context deadline exceeded") → Helm can't cleanly
  uninstall while the cluster is being deleted. Drop it from state and re-run; it dies with the
  cluster anyway: `terraform -chdir=terraform-eks state rm helm_release.<name>`, then
  `./scripts/destroy.sh`.
- **`values.yaml` looks wrong / the ALB says `CertificateNotFound`** → the file drifted from the live
  stack. Run `./scripts/sync-values-from-tf.sh --check` to see the drift and
  `./scripts/sync-values-from-tf.sh` to fix it. Never edit those fields by hand.
````

- [ ] **Step 4: Update `CLAUDE.md`'s Deployment section**

In the `## Deployment` section, replace the "**Two manual ops:**" bullet with:

```markdown
- **`./scripts/deploy.sh` / `./scripts/destroy.sh`** run the full ordered sequence (both stop for
  confirmation before Terraform touches billed resources). The env-specific fields of `values.yaml`
  (`image.tag`, `config.DB_HOST`, `config.S3_BUCKET`, `ingress.certificateArn`, `backup.roleArn`,
  `worker.roleArn`) are written by **`./scripts/sync-values-from-tf.sh`** from Terraform outputs —
  **never hand-edit them**; they change on every rebuild. `--check` mode fails on drift.
```

In the same section, replace the "**Teardown order matters:**" paragraph with:

```markdown
**Teardown order matters** and `./scripts/destroy.sh` encodes it: delete the ArgoCD Application (else
`selfHeal` recreates what you remove), then the Ingress (so the ALB de-provisions and external-dns
removes its records — a leftover ALB's ENIs block VPC deletion), wait for the ALB to disappear, *then*
`terraform destroy`. If destroy hangs uninstalling a `helm_release` ("context deadline exceeded"),
`terraform state rm` that release and re-run; it dies with the cluster anyway.
```

- [ ] **Step 5: Commit**

```bash
git add docs/deploy.md CLAUDE.md
git commit -m "docs: rewrite deploy/destroy runbook around the orchestrator scripts"
git push
```

---

### Task 7: End-to-end verification cycle

**Files:** none changed — this task proves the previous six.

**Interfaces:**
- Consumes: everything.
- Produces: a verified-working deploy path.

> **Requires explicit user go-ahead.** This destroys and rebuilds the live cluster (~20 min, real
> billing). Do not start it unattended.

- [ ] **Step 1: Static checks**

```bash
terraform -chdir=terraform-eks fmt -check -recursive
terraform -chdir=terraform-eks validate
helm lint charts/voteball
helm template voteball charts/voteball --namespace devops-app >/dev/null && echo "template OK"
./scripts/tests/test-sync-values.sh
for s in scripts/*.sh; do bash -n "$s" || echo "SYNTAX FAIL: $s"; done
```

Expected: all pass, `template OK`, `PASS: all sync-values assertions`.

- [ ] **Step 2: Tear down**

```bash
./scripts/destroy.sh
```

Expected: each step announced; ALB poll reports "ALB gone"; Terraform asks for confirmation.

- [ ] **Step 3: Assert the teardown was clean**

```bash
echo "--- DNS should be empty (H7) ---"
dig +short voteball.latnook.com @8.8.8.8
echo "--- a NEW final snapshot should exist (H4) ---"
aws rds describe-db-snapshots --snapshot-type manual --region il-central-1 \
  --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].[DBSnapshotIdentifier,SnapshotCreateTime]' --output text
echo "--- apex records must have survived external-dns sync ---"
aws route53 list-resource-record-sets --hosted-zone-id Z00371679I0OE09A8HIG \
  --query "ResourceRecordSets[?Name=='latnook.com.'].Type" --output text
```

Expected: empty DNS output; a snapshot named `voteball-eks-db-final-<timestamp>` dated just now; apex
record types still listed (proving `sync` did not over-delete).

- [ ] **Step 4: Rebuild**

```bash
./scripts/deploy.sh
```

Expected: `terraform apply` completes with **zero** webhook errors (H2), and no prompt to edit any file.

- [ ] **Step 5: Assert the deploy is correct**

```bash
echo "--- values.yaml must already be in sync (H1) ---"
./scripts/sync-values-from-tf.sh --check
echo "--- ArgoCD Application must exist (H5) ---"
kubectl get application voteball -n argocd
echo "--- pods ---"
kubectl get pods -n devops-app
echo "--- app responds with restored data (H3/H4) ---"
curl -sf https://voteball.latnook.com/api/options | head -c 120; echo
```

Expected: `--check` exits 0; Application present; all pods `Running`; `/api/options` returns seeded
leagues/clubs/parties (proving the snapshot restore worked).

- [ ] **Step 6: Commit any values drift and close out**

```bash
git status --short charts/voteball/values.yaml
# if changed:
git add charts/voteball/values.yaml
git commit -m "Deploy: sync values.yaml after rebuild"
git push
```

---

## Verification outcome (2026-07-20)

Task 7 was executed in full: `terraform apply` → `destroy.sh` → `deploy.sh` against live AWS. All nine
hazards verified. Final state: ArgoCD Synced/Healthy, 5/5 pods Running, site HTTP 200, no values drift.

**Four defects that only the end-to-end run could have caught — three introduced by this plan:**

1. **`ignore_changes = [final_snapshot_identifier]` (Task 3, Step 5) silently disabled the feature it
   accompanied.** The provider reads that field *from state* at destroy time, and `ignore_changes` kept
   it out of state, so destroy failed with "final_snapshot_identifier is required when
   skip_final_snapshot is false". RDS survived and its ENIs blocked the subnet for 20 minutes. The
   suppression was never needed — `time_static` already makes the value stable. Removed, with a comment
   so it does not come back. Fixed in `37ff708`.

2. **`destroy.sh` could not be re-run after a partial teardown.** With the cluster already gone `kubectl`
   fails `Unauthorized`, which `--ignore-not-found` does not cover, so `set -e` aborted before Terraform
   ran — disabling the recovery path exactly when it was needed. Steps 1/2/4 are now gated on cluster
   reachability. Fixed in `37ff708`.

3. **H9: ArgoCD bootstrapped before `values.yaml` was committed** — see the spec. Fixed in `3c90a9f`.

4. **H8: orphaned CNI ENIs** (pre-existing, not introduced here) — see the spec. Fixed in `559de3a`.

**Two process failures worth recording:** piping `terraform destroy` through `tail` buffered the output,
hiding the real error for ~30 minutes and forcing diagnosis from AWS state instead. The same pipe made
the run report **exit code 0 when Terraform had failed**, which was briefly reported as success. Long
infra commands must be logged unbuffered to a file, never through a pipe that masks exit status.

**Deviations from the plan as written:** `sync-values-from-tf.sh` gained an ECR-existence check for
`image.tag` and stopped comparing the tag to git HEAD in `--check` mode (HEAD moves on every docs commit,
so the preflight would have cried wolf and been ignored). `deploy.sh`/`destroy.sh` gained
`VOTEBALL_AUTO_APPROVE` for unattended runs; interactive confirmation remains the default.

## Self-Review

**Spec coverage:**

| Spec item | Task |
|---|---|
| H1 values.yaml drift | 1 |
| H2 ALB webhook race | 2 |
| H3 broken snapshot script | 3 |
| H4 snapshot SPOF | 3 |
| H5 missing ArgoCD bootstrap | 5 (script), 6 (docs) |
| H6 wrong destroy order | 5 (script), 6 (docs) |
| H7 stale DNS | 4 |
| Design §1 sync script + `--check` | 1 |
| Design §2 `enableServiceMutatorWebhook` | 2 |
| Design §3 snapshot lifecycle + `null` default + `time` provider | 3 |
| Design §4 external-dns `sync` | 4 |
| Design §5 orchestrators | 5 |
| Verification criteria 1–6 | 7 |

No gaps.

**Deviation from spec, deliberate:** the spec proposed anchored `sed` for the values rewrite. Reading
the real `values.yaml` showed `roleArn` appears under **both** `backup:` and `worker:` at identical
indentation, so `sed` would cross-assign the two IAM roles. Task 1 uses a section-aware Python
rewriter instead, and adds `worker.roleArn` (a Terraform output the spec's table omitted) to the
managed set. Test assertion 3 exists specifically to catch that cross-assignment.

**Placeholder scan:** none — every step carries full file contents or exact replacement text.

**Type consistency:** flag names (`--check`, `--tag`, `--values`), the `SYNC_STUB_<output>` convention,
the `snapshot.auto.tfvars` path, and the six managed `(section, key)` pairs are identical across
Tasks 1, 3, 5, 6 and 7.
