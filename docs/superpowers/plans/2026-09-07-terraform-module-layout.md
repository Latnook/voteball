# Terraform Module Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the AWS layer of `terraform/` into six child modules under `terraform/modules/` without changing one byte of deployed infrastructure or one character of any command the operator types.

**Architecture:** Pure state-address migration. Each task moves one module's resources into `terraform/modules/<name>/`, adds a `moved.tf` re-pointing the old state addresses at the new ones, rewires every reference in the same commit so the config stays valid, and gates on `terraform plan` reporting **no changes**. The cluster add-ons stay flat at the root and are edited only where a reference changes.

**Tech Stack:** Terraform >= 1.11, AWS provider ~> 5.0, S3 backend with `use_lockfile`, `terraform-aws-modules/{vpc,eks,iam}`.

**Spec:** `docs/design/2026-09-07-terraform-module-layout-design.md`

## Global Constraints

- **The stack is LIVE.** EKS `ACTIVE`, RDS serving, 228 resources in S3 state. A missing `moved` block reads as *destroy this database and build a new one*, and Terraform will not flag it as suspicious.
- **`terraform apply` is NEVER run in this plan.** A correct migration has an empty diff. If a task's plan is not empty, the task is wrong — fix the config, never apply.
- **Every task ends with the SAME three-command gate, in this order.** All three, every task — not just the last one. A task is not done until all three pass, and a failure is fixed before the next task starts.

  ```bash
  cd terraform && terraform validate                          # 1. config is valid
  terraform plan -var-file=voteball.tfvars                    # 2. must print "No changes."
  cd .. && scripts/tests/run-ci-suite.sh                      # 3. scripts still green
  ```

  Gate 2's pass condition is **not** `No changes.` — this stack has one pre-existing drift, measured
  before the refactor began: `kubernetes_namespace.devops_app` carries a stray `name` label applied
  outside Terraform, so a clean plan reads `0 to add, 1 to change, 0 to destroy`. The gate is that
  the plan contains **exactly that one change and nothing else**, checked mechanically against the
  machine-readable plan (`terraform show -json`), never by reading the text plan — whose parallel
  refresh lines come out in a different order every run.

  Gate 3 exists because gates 1 and 2 say nothing about `scripts/`. A refactor can leave Terraform
  perfectly happy and still break the next `./scripts/deploy.sh`, which nobody discovers until a
  rebuild.
- **The live cluster cannot be harmed by this plan, and that is structural, not careful.** No task
  runs `terraform apply`, `helm upgrade`, `kubectl apply` or any AWS write. `terraform plan` and
  `terraform output` are read-only. The blast radius is limited to committing a config that would
  break a FUTURE apply — which is exactly what gate 2 checks, on every task.
- **Baseline artifacts** (captured before task 1, in the scratchpad — do not delete until task 9):
  - `outputs-before.json` — 16 root outputs, JSON
  - `state-before.txt` — 228 state addresses
- **Nothing user-facing changes.** `voteball.tfvars` keeps its name and contents. All 16 output names and values stay identical. Every `scripts/*.sh` invocation stays the same from the operator's side.
- **Run `terraform init -backend-config=backend.hcl`** after creating any new module directory. A bare `init` fails on incomplete backend config by design.
- **Run `terraform fmt -recursive`** before every commit.
- **No `Claude-Session:` trailer in any commit message** (repo rule, `CLAUDE.md` Workflow).
- **Comments move with their resource, verbatim.** They are not summarized, not rewritten, not dropped. Several encode defects that cost real rebuilds.
- **Dated records are never edited:** `docs/design/*` (except this plan's own spec's "Verification outcome"), `docs/eks/live-cluster-snapshot.md`, `docs/eks/evidence/*`.

## File Structure

**Created — six modules, four files each:**

```
terraform/modules/networking/{main,variables,outputs}.tf   module.vpc
terraform/modules/compute/{main,variables,outputs}.tf      module.eks
terraform/modules/database/{main,variables,outputs}.tf     RDS + SG + subnet group + time_static
terraform/modules/iam/{main,variables,outputs}.tf          5 hand-rolled IRSA roles
terraform/modules/storage/{main,variables,outputs}.tf      S3 + ECR + EFS
terraform/modules/notifications/{main,variables,outputs}.tf SNS + budget
```

**Created — root:** `terraform/main.tf` (the six module calls), `terraform/moved.tf` (ALL 32 moved blocks — they cannot live inside the modules, see Task 1), `terraform/dns.tf` (from `acm.tf` + the two certs currently in add-on files).

**Created — test:** `scripts/tests/test-terraform-targets.sh`.

**Deleted:** `terraform/{vpc,eks,database,irsa,s3,ecr,sns,budget,acm,providers-k8s}.tf` — contents relocated, not dropped.

**Modified:** `terraform/{variables,outputs,providers}.tf`, the 11 `addon-*.tf`, `addons-basic.tf`, `namespaces.tf`, `secrets.tf`, `waf.tf` (reference re-pointing only), `scripts/deploy.sh`, `scripts/jenkins/install-jenkins.sh`, `scripts/tests/run-ci-suite.sh`, and the live docs listed in task 9.

---

### Task 1: `modules/notifications` — prove the pattern on the smallest module

Three inputs, three resources, two consumers. If the `moved`-block mechanism is wrong, it is cheapest to discover here.

**Files:**
- Create: `terraform/modules/notifications/{main,variables,outputs}.tf`
- Delete: `terraform/sns.tf`, `terraform/budget.tf`
- Modify: `terraform/main.tf` (create it), `terraform/outputs.tf`, `terraform/irsa.tf`, `terraform/addon-jenkins.tf`, `terraform/addon-monitoring.tf`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces: `module.notifications.sns_topic_arn` (string) — replaces `aws_sns_topic.notifications.arn` at every call site.

- [ ] **Step 1: Create the module, moving both files' contents verbatim**

`terraform/modules/notifications/main.tf` gets the full text of `sns.tf` and `budget.tf` — including `budget.tf`'s "smoke detector, not a sprinkler" comment block, unedited. Replace `var.cluster_name`, `var.notification_email`, `var.monthly_budget_usd` references with the module's own (identical names, so the resource bodies do not change at all).

`terraform/modules/notifications/variables.tf`:

```hcl
variable "cluster_name" {
  description = "Resource name prefix for this stack."
  type        = string
}

variable "notification_email" {
  description = "Address subscribed to the SNS topic and to both budget thresholds."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD."
  type        = string
}
```

`terraform/modules/notifications/outputs.tf`:

```hcl
output "sns_topic_arn" {
  description = "Milestone-alert topic the worker, Alertmanager and the CI notifier publish to."
  value       = aws_sns_topic.notifications.arn
}
```

- [ ] **Step 2: Write `moved.tf` — the load-bearing file**

`terraform/modules/notifications/moved.tf`:

```hcl
# These blocks re-point EXISTING state entries at their new addresses. Without them Terraform reads
# the relocation as "destroy the old resource, create a new one" -- and reports that as an ordinary
# plan, not as an error.
#
# They stay until the next `terraform apply` consumes them (after which state already holds the new
# addresses and these become no-ops). Do not delete them before that apply has run.
moved {
  from = aws_sns_topic.notifications
  to   = module.notifications.aws_sns_topic.notifications
}

moved {
  from = aws_sns_topic_subscription.email
  to   = module.notifications.aws_sns_topic_subscription.email
}

moved {
  from = aws_budgets_budget.monthly
  to   = module.notifications.aws_budgets_budget.monthly
}
```

**Direction — this was wrong in the first draft of this plan and Terraform rejected it.** `moved` blocks for a root→child move MUST live in the CALLING module (the root), in a single `terraform/moved.tf`. `from` is resolved relative to the module the block is written in, so a block inside `modules/notifications/` saying `from = aws_sns_topic.notifications` means `module.notifications.aws_sns_topic.notifications` — the destination, not the source — and fails with `Error: Moved object still exists`. A `moved.tf` inside a module is still correct for moves WITHIN that module; there are none in this pass.

- [ ] **Step 3: Create `terraform/main.tf` with the first module call**

```hcl
# Module wiring. Every child module under modules/ is instantiated here and nowhere else.
module "notifications" {
  source = "./modules/notifications"

  cluster_name       = var.cluster_name
  notification_email = var.notification_email
  monthly_budget_usd = var.monthly_budget_usd
}
```

- [ ] **Step 4: Re-point all four consumers**

Replace `aws_sns_topic.notifications.arn` with `module.notifications.sns_topic_arn` in:
- `terraform/outputs.tf` (`output "sns_topic_arn"`)
- `terraform/irsa.tf` (`data.aws_iam_policy_document.worker_permissions`, `alertmanager_permissions`)
- `terraform/addon-jenkins.tf`
- `terraform/addon-monitoring.tf`

Verify none remain: `grep -rn 'aws_sns_topic\.notifications' terraform/*.tf` must return nothing.

- [ ] **Step 5: Init, format, validate**

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: THE GATE — plan must be empty**

```bash
terraform plan -var-file=voteball.tfvars
```
Expected, literally: `No changes. Your infrastructure matches the configuration.`

If instead you see `aws_sns_topic.notifications will be destroyed` alongside `module.notifications.aws_sns_topic.notifications will be created`, a `moved` block is missing or misspelled. Fix `moved.tf` and re-plan. **Do not apply.**

- [ ] **Step 7: Commit**

```bash
git add terraform/ && git commit -m "refactor(terraform): extract modules/notifications

SNS topic, its email subscription and the monthly budget move into a
three-input child module. moved blocks keep all three existing state
addresses; terraform plan reports no changes."
git push origin master
```

---

### Task 2: `modules/storage`

**Files:**
- Create: `terraform/modules/storage/{main,variables,outputs}.tf`
- Delete: `terraform/s3.tf`, `terraform/ecr.tf`
- Modify: `terraform/addon-efs.tf` (EFS resources leave; the CSI add-on, its IRSA module and the StorageClass stay), `terraform/main.tf`, `terraform/outputs.tf`, `terraform/irsa.tf`, `terraform/addon-jenkins.tf`

**Interfaces:**
- Consumes: `var.cluster_name`, `data.aws_caller_identity.current.account_id`, and from Task 4/5 *not yet available* — so this task passes `vpc_id`, `private_subnets` and `node_security_group_id` from the still-root `module.vpc` / `module.eks`. Those references are updated again in Tasks 4 and 5. This is expected churn, not rework: each task must leave the config valid on its own.
- Produces:
  - `module.storage.bucket_id` (string), `module.storage.bucket_arn` (string)
  - `module.storage.ecr_repository_urls` (map(string)) — keyed `backend|worker|nginx|backup|jenkins`
  - `module.storage.ecr_repository_arns` (map(string)) — same keys, for the IAM policies in Task 6
  - `module.storage.efs_file_system_id` (string)

- [ ] **Step 1: Move the eleven resources**

Into `terraform/modules/storage/main.tf`, verbatim:
- from `s3.tf`: `aws_s3_bucket.rollups`, `aws_s3_bucket_public_access_block.rollups`, `aws_s3_bucket_versioning.rollups`
- from `ecr.tf`: `aws_ecr_repository.app`, `aws_ecr_repository.cache`, `aws_ecr_lifecycle_policy.app`, `aws_ecr_lifecycle_policy.cache`, and the `local.ecr_repos` / `local.ecr_cache_repos` locals
- from `addon-efs.tf`: `aws_efs_file_system.jenkins`, `aws_security_group.efs`, `aws_vpc_security_group_ingress_rule.efs_nfs`, `aws_efs_mount_target.jenkins`

**Two comments MUST travel unedited:**
- `ecr.tf`'s note on why the cache repos are `MUTABLE` and outside `local.ecr_repos` (adding them to the `IMMUTABLE` set fails every build's cache export, at the end of a long build).
- `addon-efs.tf`'s "WHY EFS AND NOT EBS" block and the `for_each` note above `aws_efs_mount_target.jenkins`.

- [ ] **Step 2: Variables**

```hcl
variable "cluster_name"    { type = string }
variable "account_id"      { type = string }
variable "vpc_id"          { type = string }
variable "azs"             { type = list(string) }
variable "private_subnet_cidrs" {
  description = "STATIC list, not derived from the VPC module. aws_efs_mount_target.jenkins keys its for_each on the index of this list; for_each KEYS may not be unknown at plan time, so sourcing them from module.networking.private_subnets fails a from-scratch plan with 'Invalid for_each argument'. Plans fine against a live VPC, breaks only the next rebuild from empty state (2026-08-05)."
  type        = list(string)
}
variable "private_subnet_ids" {
  description = "VALUES may be unknown at plan time; only keys may not. Safe to take from the VPC module."
  type        = list(string)
}
variable "node_security_group_id" { type = string }
```

- [ ] **Step 3: Outputs**

```hcl
output "bucket_id"  { value = aws_s3_bucket.rollups.id }
output "bucket_arn" { value = aws_s3_bucket.rollups.arn }
output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}
output "ecr_repository_arns" {
  value = { for k, r in aws_ecr_repository.app : k => r.arn }
}
output "efs_file_system_id" { value = aws_efs_file_system.jenkins.id }
```

- [ ] **Step 4: `moved.tf` — eleven blocks**

One block per address below; a single block covers every `for_each` instance, so the 5 app repos + 2 cache repos + 2 mount targets need one block each, not nine.

```
aws_s3_bucket.rollups                     aws_ecr_lifecycle_policy.cache
aws_s3_bucket_public_access_block.rollups aws_efs_file_system.jenkins
aws_s3_bucket_versioning.rollups          aws_efs_mount_target.jenkins
aws_ecr_repository.app                    aws_security_group.efs
aws_ecr_repository.cache                  aws_vpc_security_group_ingress_rule.efs_nfs
aws_ecr_lifecycle_policy.app
```

Each as `moved { from = <addr>  to = module.storage.<addr> }`, with the same header comment as Task 1 step 2.

- [ ] **Step 5: Wire it in `main.tf`**

```hcl
module "storage" {
  source = "./modules/storage"

  cluster_name           = var.cluster_name
  account_id             = data.aws_caller_identity.current.account_id
  vpc_id                 = module.vpc.vpc_id
  azs                    = var.azs
  private_subnet_cidrs   = local.private_subnet_cidrs
  private_subnet_ids     = module.vpc.private_subnets
  node_security_group_id = module.eks.node_security_group_id
}
```

- [ ] **Step 6: Re-point consumers**

- `terraform/outputs.tf`: `s3_bucket` → `module.storage.bucket_id`; `ecr_repository_urls` → `module.storage.ecr_repository_urls`
- `terraform/irsa.tf`: `aws_s3_bucket.rollups.arn` → `module.storage.bucket_arn`
- `terraform/addon-jenkins.tf`: `aws_efs_file_system.jenkins.id` → `module.storage.efs_file_system_id`; any ECR ARN reference → `module.storage.ecr_repository_arns`
- `terraform/addon-efs.tf`: `aws_efs_file_system.jenkins.id` → `module.storage.efs_file_system_id`

Verify: `grep -rn 'aws_s3_bucket\.\|aws_ecr_\|aws_efs_' terraform/*.tf` returns nothing.

- [ ] **Step 7: Init, fmt, validate, THE GATE, commit**

Same five commands as Task 1 steps 5-7. `terraform plan` must print `No changes.` Commit message: `refactor(terraform): extract modules/storage`.

---

### Task 3: `modules/iam`

Includes the Jenkins IAM currently living in `addon-jenkins.tf` (spec §3b). The eight community `module.*_irsa` instances do **not** move (spec §3a).

**Files:**
- Create: `terraform/modules/iam/{main,variables,outputs}.tf`
- Delete: `terraform/irsa.tf`
- Modify: `terraform/addon-jenkins.tf` (IAM block leaves; `module.jenkins_cd_irsa` stays), `terraform/main.tf`, `terraform/outputs.tf`, `terraform/addon-monitoring.tf`

**Interfaces:**
- Consumes: `module.storage.bucket_arn`, `module.notifications.sns_topic_arn`, `module.eks.oidc_provider`, `module.eks.oidc_provider_arn`, `data.aws_caller_identity.current.account_id`, `var.aws_region`, `var.cluster_name`.
- Produces: `module.iam.{worker,backup,grafana,alertmanager,jenkins}_role_arn` (string each), `module.iam.jenkins_cd_ecr_read_policy_arn`, `module.iam.jenkins_cd_notify_policy_arn`.

- [ ] **Step 1: Move `irsa.tf` whole, plus four blocks out of `addon-jenkins.tf`**

From `addon-jenkins.tf`, move into the module: `aws_iam_role.jenkins`, `aws_iam_role_policy.jenkins`, `aws_iam_policy.jenkins_cd_ecr_read`, `aws_iam_policy.jenkins_cd_notify`, and the four `data.aws_iam_policy_document.jenkins*` blocks they read.

Leave in `addon-jenkins.tf`: `module.jenkins_cd_irsa`, and every `helm_release`/`kubernetes_*` resource.

- [ ] **Step 2: Variables and outputs**

```hcl
# variables.tf
variable "cluster_name"      { type = string }
variable "aws_region"        { type = string }
variable "account_id"        { type = string }
variable "oidc_provider"     { type = string }
variable "oidc_provider_arn" { type = string }
variable "bucket_arn"        { type = string }
variable "sns_topic_arn"     { type = string }
```

```hcl
# outputs.tf
output "worker_role_arn"       { value = aws_iam_role.worker.arn }
output "backup_role_arn"       { value = aws_iam_role.backup.arn }
output "grafana_role_arn"      { value = aws_iam_role.grafana.arn }
output "alertmanager_role_arn" { value = aws_iam_role.alertmanager.arn }
output "jenkins_role_arn"      { value = aws_iam_role.jenkins.arn }
output "jenkins_cd_ecr_read_policy_arn" { value = aws_iam_policy.jenkins_cd_ecr_read.arn }
output "jenkins_cd_notify_policy_arn"   { value = aws_iam_policy.jenkins_cd_notify.arn }
```

- [ ] **Step 3: `moved.tf` — twelve blocks**

```
aws_iam_role.worker           aws_iam_role_policy.worker
aws_iam_role.backup           aws_iam_role_policy.backup
aws_iam_role.grafana          aws_iam_role_policy.grafana
aws_iam_role.alertmanager     aws_iam_role_policy.alertmanager
aws_iam_role.jenkins          aws_iam_role_policy.jenkins
aws_iam_policy.jenkins_cd_ecr_read
aws_iam_policy.jenkins_cd_notify
```

- [ ] **Step 4: Wire, re-point, gate, commit**

`main.tf` gains the `module "iam"` block. Re-point `terraform/outputs.tf` (`worker_role_arn`, `backup_role_arn`), `addon-monitoring.tf` (`aws_iam_role.grafana.arn`, `aws_iam_role.alertmanager.arn`), `addon-jenkins.tf` (`aws_iam_role.jenkins.arn`, both `aws_iam_policy.jenkins_cd_*.arn`).

Verify: `grep -rn 'aws_iam_role\.\|aws_iam_policy\.' terraform/*.tf` returns nothing.

`terraform plan` must print `No changes.` Commit: `refactor(terraform): extract modules/iam`.

---

### Task 4: `modules/networking`

**Files:**
- Create: `terraform/modules/networking/{main,variables,outputs,moved}.tf`
- Delete: `terraform/vpc.tf`
- Modify: `terraform/main.tf`, `terraform/eks.tf`, `terraform/database.tf`, `terraform/addon-alb.tf`, `terraform/addon-efs.tf`, `terraform/addon-jenkins.tf`

**Interfaces:**
- Consumes: `var.cluster_name`, `var.vpc_cidr`, `var.azs`, `local.private_subnet_cidrs`.
- Produces: `module.networking.{vpc_id, vpc_cidr_block, private_subnets, database_subnets, public_subnets_cidr_blocks}`.

- [ ] **Step 1: Move `module "vpc"` into the child module**

`local.private_subnet_cidrs` moves to the ROOT (`main.tf`), not into the module — it is consumed by both `networking` and `storage`, and by `addon-efs.tf`. Its explanatory comment moves with it.

- [ ] **Step 2: `moved.tf` — ONE block moves all 24 state entries**

```hcl
moved {
  from = module.vpc
  to   = module.networking.module.vpc
}
```

A `moved` block naming a module moves its entire subtree. Do not write 24 individual blocks.

- [ ] **Step 3: Wire, re-point every `module.vpc.*` reference to `module.networking.*`, gate, commit**

Verify: `grep -rn 'module\.vpc\.' terraform/*.tf` returns nothing (references inside `modules/networking/` are fine — they are the module's own).

`terraform plan` must print `No changes.` Commit: `refactor(terraform): extract modules/networking`.

---

### Task 5: `modules/compute`

**Files:**
- Create: `terraform/modules/compute/{main,variables,outputs}.tf`
- Delete: `terraform/eks.tf`
- Modify: `terraform/main.tf`, `terraform/providers.tf`, `terraform/providers-k8s.tf`, `terraform/database.tf`, `terraform/namespaces.tf`, all 11 `addon-*.tf`, `terraform/outputs.tf`

**Interfaces:**
- Consumes: `var.cluster_name`, `var.cluster_version`, `var.cluster_endpoint_public_access_cidrs`, `var.node_{instance_types,min_size,max_size,desired_size}`, `module.networking.{vpc_id,private_subnets}`.
- Produces: `module.compute.{cluster_name, cluster_endpoint, cluster_certificate_authority_data, oidc_provider, oidc_provider_arn, node_security_group_id, cluster_service_cidr}`.

- [ ] **Step 1: Move `module "eks"`, preserving the endpoint-CIDR comment**

The comment explaining that `cluster_endpoint_public_access_cidrs` has no default (a plan fails until `voteball.tfvars` names a CIDR) moves with the module.

- [ ] **Step 2: `moved.tf` — ONE block, 49 state entries**

```hcl
moved {
  from = module.eks
  to   = module.compute.module.eks
}
```

- [ ] **Step 3: Re-point every `module.eks.*` reference**

This is the widest fan-out in the plan — 11 add-on files plus the providers. `depends_on = [module.eks]` in `namespaces.tf` becomes `depends_on = [module.compute]`; the EKS access-entry race comment stays.

**The providers are the subtle one.** `providers-k8s.tf` configures the `kubernetes` and `helm` providers from `module.eks` outputs. After this task they read `module.compute.*`. Note the deliberate asymmetry preserved from the current file: `kubernetes` is SDKv2 and keeps `exec {}` **block** syntax; `helm` is v3/Plugin Framework and needs `kubernetes = {}` / `exec = {}` **attribute** syntax. Do not "make them consistent."

Verify: `grep -rn 'module\.eks\.' terraform/*.tf` returns nothing.

- [ ] **Step 4: Gate and commit**

`terraform plan` must print `No changes.` Commit: `refactor(terraform): extract modules/compute`.

---

### Task 6: `modules/database`

**Files:**
- Create: `terraform/modules/database/{main,variables,outputs}.tf`
- Delete: `terraform/database.tf`
- Modify: `terraform/main.tf`, `terraform/outputs.tf`

**Interfaces:**
- Consumes: `var.cluster_name`, `var.db_{username,password,snapshot_identifier}`, `module.networking.{vpc_id,database_subnets}`, `module.compute.node_security_group_id`.
- Produces: `module.database.endpoint` (string — `aws_db_instance.app.address`).

- [ ] **Step 1: Move all four resources with every comment intact**

`aws_db_subnet_group.app`, `aws_security_group.rds`, `time_static.deploy`, `aws_db_instance.app`.

**Critical, verbatim:** the `NOTE: do NOT add lifecycle { ignore_changes = [final_snapshot_identifier] }` block and the `ignore_changes = [username]` explanation. The first prevents a destroy failure that wedges VPC teardown; the second prevents a proposed replacement of the whole instance.

`time_static` needs the `time` provider — already in the root `required_providers`, and child modules inherit providers by default, so no `required_providers` block is needed in the module. Do not add one; adding one without a matching `providers = {}` argument changes nothing, but adding one *with* a different version constraint is a hard error.

- [ ] **Step 2: `moved.tf` — four blocks**

- [ ] **Step 3: Wire, re-point `outputs.tf`'s `rds_endpoint` → `module.database.endpoint`, gate, commit**

`terraform plan` must print `No changes.` Commit: `refactor(terraform): extract modules/database`.

---

### Task 7: Root file reorganization

No state addresses change in this task — moving a resource between two root `.tf` files is free. The gate is still an empty plan, because a mistake here is a typo, not a move.

**Files:**
- Create: `terraform/dns.tf`
- Delete: `terraform/acm.tf`, `terraform/providers-k8s.tf`
- Modify: `terraform/providers.tf`, `terraform/addon-jenkins.tf`, `terraform/addon-eck.tf`

- [ ] **Step 1: Build `dns.tf`**

Move in: `data.aws_route53_zone.primary` (from `providers.tf`), all of `acm.tf`, plus `aws_acm_certificate.jenkins` + `aws_route53_record.jenkins_cert_validation` + `aws_acm_certificate_validation.jenkins` (from `addon-jenkins.tf`) and the three `kibana` equivalents (from `addon-eck.tf`).

Result: all nine ACM/Route53 resources and the zone lookup in one file.

- [ ] **Step 2: Merge `providers-k8s.tf` into `providers.tf`**

Keep `data.aws_caller_identity.current` in `providers.tf`. Preserve the SDKv2-vs-Plugin-Framework comment from Task 5 step 3.

- [ ] **Step 3: `terraform fmt -recursive`, validate, gate, commit**

`terraform plan` must print `No changes.` Commit: `refactor(terraform): collect DNS/ACM into dns.tf, merge k8s providers`.

---

### Task 8: `scripts/tests/test-terraform-targets.sh` — pin the stale-`-target` failure mode

A stale `-target=` does not error. Terraform prints `Warning: Resource targeting is in effect` and applies **nothing** — `deploy.sh` runs fast, exits 0, and creates no ECR repositories. This is the "a pattern that can never match" defect class from `CLAUDE.md`, and it is the one this refactor is most likely to introduce.

**Files:**
- Create: `scripts/tests/test-terraform-targets.sh`
- Modify: `scripts/deploy.sh:211`, `scripts/jenkins/install-jenkins.sh:18-19`, `scripts/tests/run-ci-suite.sh`

**Interfaces:**
- Consumes: nothing. Pure grep over `scripts/` and `terraform/`; no terraform binary, no AWS, no network.
- Produces: nothing importable — a test.

- [ ] **Step 1: Write the test so it FAILS first**

Write the script before fixing `deploy.sh`, so its first run proves it can actually catch the real, currently-broken addresses.

The script extracts every `-target=<address>` from `scripts/**/*.sh`, then resolves each:
- `module.<name>.<type>.<res>` → assert `resource "<type>" "<res>"` exists in `terraform/modules/<name>/*.tf`
- `<type>.<res>` (no module prefix) → assert it exists in `terraform/*.tf` (root only)
- `data.<type>.<res>` → same, as a `data` block

- [ ] **Step 2: Run it — it must FAIL, naming the two stale addresses**

```bash
scripts/tests/test-terraform-targets.sh
```
Expected: FAIL, naming `aws_ecr_repository.app`, `aws_ecr_repository.cache` (deploy.sh) and `aws_efs_file_system.jenkins`, `aws_efs_mount_target.jenkins` (install-jenkins.sh) as addresses that exist in no root `.tf`.

**If it passes here, the test is broken, not the scripts.** That is the whole point of running it before the fix — a check that can never match is indistinguishable from a correct negative.

- [ ] **Step 3: Fix the two scripts**

- `scripts/deploy.sh:211`: `-target=aws_ecr_repository.app` → `-target=module.storage.aws_ecr_repository.app`; same for `.cache`.
- `scripts/jenkins/install-jenkins.sh:18-19`: `-target=aws_efs_file_system.jenkins` → `-target=module.storage.aws_efs_file_system.jenkins`; same for `aws_efs_mount_target.jenkins`.

Leave alone (verified root-resident): `deploy.sh:212-215`, `install-jenkins.sh:20-23`, `configure-jenkins.sh:65-66`, `uninstall-jenkins.sh:27-28`.

- [ ] **Step 4: Run it again — must PASS**

- [ ] **Step 5: Prove the check can still fail (mutation test)**

Temporarily change one fixed address to `module.storage.aws_ecr_repository.nonexistent`, run the test, confirm it FAILS naming that address, then revert. A test that only ever passes proves nothing.

- [ ] **Step 6: Register it in `run-ci-suite.sh`**

Add `test-terraform-targets.sh` to `GIT_GROUP` (it is pure grep; placed there for the same reason `test-logging-teardown.sh` is — `GIT_GROUP` is the smaller container, nothing about it prefers git). The suite fails if a test file appears in no group, so this step is not optional.

- [ ] **Step 7: Run the full suite and commit**

```bash
scripts/tests/run-ci-suite.sh
```
Expected: `PASS — all N script tests green [group: all]`, with N one higher than before.

Commit: `test(terraform): assert every -target= address exists in the config`.

---

### Task 9: Docs, final verification, plan deletion

**Files:**
- Modify: `CLAUDE.md`, `docs/security.md:30`, `docs/eks/architecture.md:444`, `docs/deploy.md`, `scripts/build-push-ecr.sh:74`, `scripts/ci/{images-exist,resolve-digests,rollback-target}.sh`, `Jenkinsfile-cd:146`, `scripts/deploy.sh:188`, `docs/design/2026-09-07-terraform-module-layout-design.md` (Verification outcome)
- Delete: `docs/superpowers/plans/2026-09-07-terraform-module-layout.md` (this file) and the `docs/superpowers/` tree

- [ ] **Step 1: Update every LIVE doc citing a moved path**

`terraform/irsa.tf` → `terraform/modules/iam/main.tf`; `terraform/s3.tf`/`ecr.tf` → `terraform/modules/storage/main.tf`; `terraform/database.tf` → `terraform/modules/database/main.tf`; `terraform/vpc.tf`/`eks.tf` → `terraform/modules/{networking,compute}/main.tf`; `terraform/acm.tf` → `terraform/dns.tf`.

Add a short "Terraform layout" paragraph to `CLAUDE.md`'s Deployment section pointing at the spec.

**Do NOT touch:** `docs/design/*` other than this pass's own spec, `docs/eks/live-cluster-snapshot.md`, `docs/eks/evidence/*`. They correctly describe the layout as of their date.

- [ ] **Step 2: Prove the alternation trap did not bite**

`CLAUDE.md` records that a multi-alternative grep shares a single point of failure. So sweep for the narrowest token that must appear regardless of surrounding words:

```bash
grep -rn 'terraform/[a-z-]*\.tf' --include='*.md' --include='*.sh' --include='Jenkinsfile*' . \
  | grep -v '^./docs/design/\|^./docs/eks/live-cluster-snapshot.md\|^./docs/eks/evidence/'
```
Every hit must name a file that still exists. Check each with `ls`.

- [ ] **Step 3: THE USER-FACING GATE — outputs byte-identical**

```bash
cd terraform && terraform output -json > /tmp/.../outputs-after.json
diff <(jq -S . /tmp/.../outputs-before.json) <(jq -S . /tmp/.../outputs-after.json) && echo "IDENTICAL"
```
Expected: `IDENTICAL`, no diff lines. All 16 outputs, same names, same values.

- [ ] **Step 4: End-to-end — the chart values still round-trip**

```bash
./scripts/sync-values-from-tf.sh --check
```
Expected: pass. This reads the terraform outputs and compares them against the ten managed fields in `charts/voteball/values.yaml` — the closest thing to "the operator's side is unchanged" that can be checked without a deploy.

- [ ] **Step 5: Full suite + final empty plan**

```bash
scripts/tests/run-ci-suite.sh
cd terraform && terraform plan -var-file=voteball.tfvars
```
Expected: suite green; plan prints `No changes.`

- [ ] **Step 6: Fill in the spec's "Verification outcome"**

Record: the final state-entry count (must still be 228), that all 16 outputs matched byte-for-byte, that `sync-values-from-tf.sh --check` passed, and that no `terraform apply` was run — so the `moved` blocks are still pending and must not be deleted until one has.

- [ ] **Step 7: Delete this plan, same commit as the last task**

```bash
rm -rf docs/superpowers/
git add -A
git commit -m "docs(terraform): repoint docs at the module layout, record verification

Deletes the implementation plan now that it is executed, per CLAUDE.md."
git push origin master
```

## Self-Review

**Spec coverage:** §1 rationale → recorded in the spec, no task needed. §2 layout → Tasks 1-7. §3 the 32 moved blocks → Tasks 1(3), 2(11), 3(12), 4(1), 5(1), 6(4) = 32. ✓ §3a community IRSA modules stay → Task 3 step 1. §3b Jenkins IAM → Task 3. §4 both carried comments → Task 2 step 1, Task 6 step 1. §5 callers → Task 8; docs → Task 9. §6 verification → every task's gate, plus Task 9 steps 3-5.

**Placeholder scan:** no TBD/TODO. The `/tmp/.../` in Task 9 step 3 is the session scratchpad path, resolved at execution.

**Type consistency:** `module.storage.bucket_arn` (Task 2) is consumed as `bucket_arn` in Task 3. `module.storage.ecr_repository_arns` (Task 2) consumed by Task 3's Jenkins policies. `module.compute.node_security_group_id` (Task 5) consumed by Task 6 — and by Task 2, which reads it from the still-root `module.eks` and is re-pointed in Task 5. Flagged in Task 2's Interfaces block as expected churn. ✓
