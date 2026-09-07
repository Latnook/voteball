# Terraform module layout (2026-09-07)

`terraform/` was 30 flat `.tf` files at the root module. This pass groups the **AWS layer** into six
child modules under `terraform/modules/` and leaves the **cluster add-on layer** flat at the root.

Nothing about the deployed infrastructure changes. This is a pure state-address migration, executed
with `moved` blocks and verified by a `terraform plan` that must report **no changes**.

The stack was live throughout (EKS `ACTIVE`, RDS serving, 228 resources in S3 state), which is what
sets the safety bar: a missing `moved` block does not read as an error, it reads as *destroy this
database and build a new one*.

## 1. Why six modules and not seven

The six modules exist because each has a **small interface**, and a small interface is the signal
that a boundary is real rather than decorative. Measured — the count of values each group references
but does not define:

| Module | Inputs | One-sentence job |
|---|---|---|
| `notifications` | 3 | Where this stack sends alerts and cost warnings. |
| `storage` | 4 | The buckets, registries and filesystems it writes to. |
| `networking` | 5 | The VPC and its subnets. |
| `database` | 7 | The Postgres instance and the two objects that place it. |
| `iam` | 7 | The hand-rolled IRSA roles the workloads assume. |
| `compute` | 9 | The EKS cluster and its node group. |
| *(rejected)* `platform` | **29** | *ArgoCD and Jenkins and Prometheus and Fluent Bit and…* |

The thirteen add-on files (eleven `addon-*.tf`, plus `addons-basic.tf` and `namespaces.tf`) were
measured as a candidate seventh module and rejected. They reference 29 distinct values they do not define — five VPC outputs, five EKS outputs, three Secrets
Manager secrets, two IAM roles, an SNS topic, four `local`s and nine root variables. Wrapping them
costs roughly 90 lines of pass-through plumbing (a `variable` block, a wiring line and every
reference rewritten, per input) and buys neither of the two things a module is for:

- **Reuse** — this stack is single-environment by design (`CLAUDE.md`, "Key constraints"). Nothing
  will ever instantiate the add-ons a second time.
- **A smaller unit to reason about** — the same 1,400 lines, one directory deeper, plus the plumbing.

A narrower variant — a `platform` module holding only the four cheap add-ons (`metrics-server`,
`node-termination-handler`, `external-dns`, `external-secrets`; 4 inputs between them) — was also
rejected. Its job would be "the add-ons that happened to be easy to extract," which is not a job. An
arbitrary boundary is worse than a missing one, because a reader trusts it.

**The rule this pass used, and the one to apply next time: if a module's job needs the word "and" to
state, the boundary is in the wrong place.**

There is a risk asymmetry too. Under the flat layout the thirteen add-on files are **not edited at
all**, so the refactor is structurally incapable of breaking Jenkins, ArgoCD or the monitoring
stack. Under `platform` every one of them is rewritten while the cluster serves traffic.

## 2. The layout

```
terraform/
├── main.tf              # the six module calls, and the locals they share
├── dns.tf               # data.aws_route53_zone.primary + all 3 ACM certs + validations
├── providers.tf         # aws + kubernetes + helm (providers-k8s.tf merged in)
├── versions.tf
├── backend.tf
├── variables.tf         # unchanged — 19 root variables, same names
├── outputs.tf           # unchanged — 16 root outputs, same names, now forwarding from modules
├── secrets.tf           # 3 Secrets Manager containers + placeholder versions
├── waf.tf
├── namespaces.tf
├── addons-basic.tf      ┐
├── addon-alb.tf         │
├── addon-argocd.tf      │
├── addon-autoscaler.tf  │
├── addon-cloudwatch.tf  │  unchanged except where a reference is
├── addon-ebs.tf         ├─ re-pointed at a module output
├── addon-eck.tf         │  (module.eks.x -> module.compute.x)
├── addon-efs.tf         │
├── addon-eso.tf         │
├── addon-external-dns.tf│
├── addon-jenkins.tf     │
├── addon-monitoring.tf  ┘
└── modules/
    ├── compute/       main.tf outputs.tf variables.tf moved.tf
    ├── database/      main.tf outputs.tf variables.tf moved.tf
    ├── iam/           main.tf outputs.tf variables.tf moved.tf
    ├── networking/    main.tf outputs.tf variables.tf moved.tf
    ├── notifications/ main.tf outputs.tf variables.tf moved.tf
    └── storage/       main.tf outputs.tf variables.tf moved.tf
```

`voteball.tfvars` keeps its name. An explicit `-var-file` is safer than the auto-loaded
`terraform.tfvars` the reference layout uses: auto-loading applies on *every* command in the
directory, so a stray `plan` cannot quietly pick up values nobody passed it. Renaming would also
touch `deploy.sh`, `destroy.sh`, `.gitignore` and the runbooks for no functional gain.

The S3 backend stays. The reference layout keeps `terraform.tfstate` and a `terraform.tfstate.d/`
workspace tree on local disk; adopting that would undo
`docs/design/2026-07-21-terraform-remote-state-design.md` and put the only copy of the record of
what exists in AWS on one laptop.

## 3. Module contents and the 32 `moved` blocks

Data sources need no `moved` block — they are re-read on every plan, not migrated.

| Module | From | `moved` blocks | Addresses |
|---|---|---|---|
| `networking` | `vpc.tf` | 1 | `module.vpc` (24 state entries move as one subtree) |
| `compute` | `eks.tf` | 1 | `module.eks` (49 entries, same) |
| `database` | `database.tf` | 4 | `aws_db_instance.app`, `aws_db_subnet_group.app`, `aws_security_group.rds`, `time_static.deploy` |
| `iam` | `irsa.tf` + the IAM block of `addon-jenkins.tf` | 12 | `aws_iam_role.{worker,backup,grafana,alertmanager,jenkins}`, `aws_iam_role_policy.{worker,backup,grafana,alertmanager,jenkins}`, `aws_iam_policy.{jenkins_cd_ecr_read,jenkins_cd_notify}` |
| `storage` | `s3.tf`, `ecr.tf`, EFS half of `addon-efs.tf` | 11 | `aws_s3_bucket.rollups`, `aws_s3_bucket_public_access_block.rollups`, `aws_s3_bucket_versioning.rollups`, `aws_ecr_repository.{app,cache}`, `aws_ecr_lifecycle_policy.{app,cache}`, `aws_efs_file_system.jenkins`, `aws_efs_mount_target.jenkins`, `aws_security_group.efs`, `aws_vpc_security_group_ingress_rule.efs_nfs` |
| `notifications` | `sns.tf`, `budget.tf` | 3 | `aws_sns_topic.notifications`, `aws_sns_topic_subscription.email`, `aws_budgets_budget.monthly` |

A single `moved` block covers every instance of a `for_each` resource, so the seven ECR repositories
and two EFS mount targets need one block each, not nine.

Dependency order is acyclic: `networking → compute → {database, iam}`, with `storage` and
`notifications` feeding `iam` (bucket ARN, topic ARN) and nothing feeding back.

### 3a. The eight community `*_irsa` modules do not move

`addon-{alb,autoscaler,cloudwatch,ebs,efs,eso,external-dns}.tf` and `addon-jenkins.tf` each
instantiate `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`. Those stay
where they are, beside the add-on that needs them — 61 state entries that do not move at all.

`modules/iam` therefore means **the hand-rolled IRSA roles**, not "every IAM object in the stack."
The two are distinguishable at a glance (`module.*_irsa` vs `module.iam.aws_iam_role.*`) and the
alternative — dragging eight community modules away from their consumers — would reintroduce exactly
the long-distance coupling this pass is removing.

### 3b. Jenkins' IAM moves out of `addon-jenkins.tf`

`aws_iam_role.jenkins`, its inline policy, and the two `aws_iam_policy.jenkins_cd_*` managed
policies currently sit in `addon-jenkins.tf` rather than `irsa.tf`. They move to `modules/iam` with
the other four hand-rolled roles.

This is the one change in the pass that is not a pure relocation of an existing file's contents, and
it is deliberate: leaving them behind would make `modules/iam` hold four of five hand-rolled roles,
which makes "where does IAM live?" unanswerable and guarantees the next role is filed by coin-flip.
`addon-jenkins.tf` drops from 439 to roughly 330 lines and gains one cross-module reference
(`module.iam.jenkins_role_arn`).

## 4. Two constraints carried across verbatim

Both are load-bearing comments attached to resources that move. They travel with the resource; the
reasoning is not restated in the new location, it is *moved* there.

- **`private_subnet_cidrs` stays a plan-time-known static list.** It is declared at the root and
  passed *into* `networking`. `networking` still outputs `private_subnets` (the subnet **IDs**, which
  `compute` and `storage` consume normally) — the point is that the **CIDR list** must not be derived
  from it.
  `addon-efs.tf` keys its mount-target `for_each` on it, and `for_each` **keys** may not be unknown
  at plan time (values may). Sourcing it from a module output that does not exist until the subnets
  do fails a from-scratch plan with `Invalid for_each argument` — hit for real on the 2026-08-05
  rebuild, and recorded again at `ecr.tf:70` from 2026-07-30. It plans fine against a live VPC and
  breaks only the next rebuild from empty state, which is the worst possible failure schedule.

- **`aws_db_instance.app` keeps `ignore_changes = [username]` and must never gain
  `ignore_changes = [final_snapshot_identifier]`.** The provider reads the snapshot identifier *from
  state* at destroy time, so suppressing it stops the value ever being stored, destroy fails with
  `final_snapshot_identifier is required`, and the surviving instance's ENIs then block subnet and
  VPC teardown (2026-07-20). The full comment moves into `modules/database/main.tf`.

## 5. Callers that must change in the same commit

Two live scripts pass `-target=` addresses that this pass invalidates. A stale `-target` does not
error — Terraform reports `Warning: Resource targeting is in effect` and applies **nothing**, which
looks like a fast, clean run.

| File | Address today | After |
|---|---|---|
| `scripts/deploy.sh:211` | `aws_ecr_repository.app`, `aws_ecr_repository.cache` | `module.storage.…` |
| `scripts/jenkins/install-jenkins.sh:18-19` | `aws_efs_file_system.jenkins`, `aws_efs_mount_target.jenkins` | `module.storage.…` |

Unaffected and checked:

- `deploy.sh:212-215` targets `aws_secretsmanager_secret_version.*` and
  `data.aws_caller_identity.current`, all of which stay at the root module.
- `install-jenkins.sh:20-23`, `configure-jenkins.sh:65-66`, `uninstall-jenkins.sh:27-28` target
  `aws_eks_addon.efs_csi`, `kubernetes_storage_class.efs` and the two `helm_release`s — all root.
- `destroy.sh`'s state-rm recovery filter is already module-path-aware
  (`(^|\.)(helm_release|kubernetes_[a-zA-Z0-9_]+)\.[^.]+(\[[0-9]+\])?$`) and keeps its guarantee of
  never dropping an `aws_*` address, which after this pass are all module-nested anyway.
- `.gitignore` needs no change: its terraform rules name specific files, none of which glob into
  `modules/`.

**Live** docs citing a moved file path are updated in the same commit: `CLAUDE.md`,
`docs/security.md:30` (`terraform/irsa.tf`), `docs/eks/architecture.md:444` (`terraform/addon-efs.tf`),
`scripts/build-push-ecr.sh:74`, `scripts/ci/{images-exist,resolve-digests,rollback-target}.sh`,
`Jenkinsfile-cd:146`, `scripts/deploy.sh:188`.

**Dated records are not touched** — `docs/design/*`, `docs/eks/live-cluster-snapshot.md` and
`docs/eks/evidence/*` correctly describe the layout as it was on their date. Editing them would
destroy the record.

## 6. Verification

In order. Nothing is committed before step 3 passes.

1. `terraform fmt -recursive` and `terraform validate`.
2. `terraform init -backend-config=backend.hcl` — required to register the new local modules, and
   the backend config is partial by design so a bare `init` fails rather than falling back to local
   state.
3. **`terraform plan -var-file=voteball.tfvars` must print `No changes. Your infrastructure matches
   the configuration.`** Any proposed create, destroy or replace means a `moved` block is missing or
   misspelled. Fix and re-plan. This is the whole safety argument: the error surfaces on a plan, for
   free, and never reaches an apply.
4. `scripts/tests/run-ci-suite.sh`.

`terraform apply` is **not** run as part of this pass. There is nothing to apply — a correct
migration produces an empty diff by definition, and `moved` blocks are consumed by the next apply
whenever one naturally happens.

### What a missing `moved` block looks like

Worth knowing by sight, since step 3 is the only thing standing in front of it:

```
  # aws_db_instance.app will be destroyed
  # (because aws_db_instance.app is not in configuration)
  - resource "aws_db_instance" "app" { ... }

  # module.database.aws_db_instance.app will be created
  + resource "aws_db_instance" "app" { ... }
```

Terraform does not flag this as suspicious. It is a correct plan for the configuration as written —
which is precisely why the gate is "the plan says *no changes*", not "the plan looks reasonable".

## Verification outcome

*(to be filled in once the migration runs)*
