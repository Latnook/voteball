# Terraform remote state: S3 backend for both stacks

Status: designed 2026-07-21. Addresses gap **§1** of `docs/production-readiness.md` ("Terraform state
is a local file — highest risk"), and partially **§7** (the Jenkins host's state has the same
exposure, which §1 does not mention).

---

## Problem

Neither Terraform stack declares a `backend`, so each keeps its state as a file on one laptop:

| Stack | State file | Resources (2026-07-21) |
|---|---|---|
| `terraform/` | `terraform/terraform.tfstate` | **0** — the cluster was destroyed 2026-07-20 |
| `terraform/jenkins/` | `terraform/jenkins/terraform.tfstate` | **14** — live EC2, EIP, IAM role, SG, key pair |

Terraform's state is the mapping from the configuration to the real AWS object IDs it created.
Losing it does not stop those objects: they keep running and keep billing, but Terraform can no
longer see, change or destroy them. Recovery is importing every resource by hand, or deleting them
through the console and hoping the list was complete.

Three consequences follow from the file being local:

1. **No durability.** One disk, no versioning, no copy. `scripts/destroy.sh` writes
   `terraform.tfstate.<epoch>.backup` files beside it, which is not a backup — same disk.
2. **No locking.** Two concurrent runs corrupt the file, with no mechanism to prevent it.
3. **Single machine.** Only this laptop can ever run Terraform against these stacks.

### The exposure is inverted from what §1 assumes

`docs/production-readiness.md` §1 names only the main stack. Today that is the *less* urgent of the
two: its state describes nothing, so losing it costs nothing. The file that matters is the Jenkins
stack's — 14 live resources, including the CI host whose configuration exists nowhere else. This is
the same risk §7 calls "real but low-probability, accepted for now"; remote state removes half of it
(the loss of the *record*) even before JCasC removes the other half (the loss of the *configuration*).

**This is also the cheapest moment this migration will ever have.** The main stack's state is empty,
so moving it is a formality. After the redeploy (project C) the same operation moves a record of 112
live resources.

---

## Non-goals

- **Not** moving the app, cluster or Jenkins host. No running resource is touched.
- **Not** deleting the existing local state files. They remain on disk as the rollback path; pruning
  them is a separate, later decision.
- **Not** multi-environment state layout (`env/dev`, `env/prod`). A single environment is a standing
  project constraint.
- **Not** CI-driven Terraform. Jenkins holds no cluster credentials by design and will not gain
  Terraform access; the backend is for a human operator.
- **Not** encrypting state with a customer-managed KMS key. SSE-S3 is used; see Risks.

---

## Design

### 1. One bucket, two keys

A single bucket, `<cluster_name>-tfstate-<account_id>`, holding both stacks' state under separate
keys:

| Stack | Key |
|---|---|
| `terraform/` | `voteball/main.tfstate` |
| `terraform/jenkins/` | `voteball/jenkins.tfstate` |

Separate keys mean separate objects and separate locks, so the two stacks remain as independent as
they are today — the main stack can be destroyed and rebuilt repeatedly without the Jenkins stack
noticing. One bucket rather than two means one thing to create, protect and reason about.

The account id is in the name because S3 bucket names are globally unique across all AWS customers;
`voteball-tfstate` alone would collide. The `cluster_name` prefix keeps it consistent with every
other resource in the repo.

### 2. The bucket belongs to no stack

Nothing manages the bucket in Terraform, and **`scripts/destroy.sh` must never touch it** — for the
same reason `terraform/jenkins/` is outside that script's scope. A state bucket destroyed by the
stack whose state it holds is the same class of error as a CI server owned by the stack it builds
for: the teardown removes the record of what it is tearing down, mid-operation.

### 3. Bootstrap is a shell script, not Terraform

Terraform cannot create the bucket it stores its own state in — the bucket must exist before
`init` runs. The alternative, a small separate Terraform stack, only relocates the problem: *that*
stack's state is then the unprotected local file.

`scripts/bootstrap-tf-backend.sh` therefore creates it with the AWS CLI. It is **idempotent** — safe
to re-run, creating nothing that already exists — and has no state of its own to lose. This matches
how the repo's other one-off operations already work (`seed-eks-secret.sh`,
`find-latest-snapshot.sh`, `cleanup-stale-dns.sh`).

It applies, and re-asserts on every run:

- **Versioning enabled** — every past state is retained, so a corrupted or truncated state is
  recoverable by restoring the previous version. This is the single most valuable property here.
- **Server-side encryption** (SSE-S3, `AES256`). State contains secrets — the RDS master password
  among them.
- **Public access block**, all four settings.
- **Bucket policy denying non-TLS access** (`aws:SecureTransport: false`).
- **Lifecycle rule** expiring noncurrent versions after 90 days, so version history does not grow
  without bound (the concern raised in §8, applied pre-emptively).

Region and account id are resolved at runtime — via `scripts/lib/config.sh` and
`aws sts get-caller-identity` — never hardcoded, per the repo's forkability rule.

### 4. Locking: `use_lockfile`, not DynamoDB

Terraform 1.11 deprecated the `dynamodb_table` backend argument in favour of `use_lockfile = true`,
which holds the lock as an S3 object using conditional writes. The installed toolchain is **1.15.8**,
so the built-in path is available: no DynamoDB table to create, pay for, or migrate off later.

**Cost of the choice:** `required_version` rises from `>= 1.5.0` to `>= 1.11.0` in both stacks'
`versions.tf`. Nobody is currently affected, and the alternative is adopting a mechanism already
scheduled for removal.

### 5. Partial backend configuration (`backend.hcl`)

Terraform **does not permit variables, locals or interpolation inside a `backend` block** — it is
evaluated before the rest of the configuration exists. The bucket name contains the AWS account id,
so writing it literally into `backend.tf` would hardcode account identity into a committed file,
violating the repo's central rule in the one place the usual escape hatch is unavailable.

The resolution is **partial configuration**: the committed block carries only what is
environment-independent, and the rest arrives at `init` time.

```hcl
# terraform/backend.tf — committed
terraform {
  backend "s3" {
    # bucket / key / region come from backend.hcl (generated, gitignored):
    #   terraform init -backend-config=backend.hcl
    # A backend block cannot interpolate variables, so identity cannot live here.
    use_lockfile = true
    encrypt      = true
  }
}
```

```hcl
# terraform/backend.hcl — generated by bootstrap-tf-backend.sh, GITIGNORED
bucket = "voteball-tfstate-123456789012"
key    = "voteball/main.tfstate"
region = "il-central-1"
```

This is the same shape as the existing `voteball.tfvars` / `voteball.tfvars.example` pair, extended
to the one file that variables cannot reach. `backend.hcl.example` is committed for both stacks.

Because only the bootstrap script knows the account id at the moment it resolves it, that script has
two jobs: create the bucket **and** write the `backend.hcl` that points at it. If the two ever
disagree, `terraform init` fails loudly before touching any state — the correct failure direction.

### 6. Repository changes

| File | Change |
|---|---|
| `scripts/bootstrap-tf-backend.sh` | **new** — idempotent bucket creation + `backend.hcl` generation |
| `scripts/tests/test-bootstrap-backend.sh` | **new** — offline, stubbed AWS CLI |
| `terraform/backend.tf` | **new** — partial `backend "s3"` block |
| `terraform/jenkins/backend.tf` | **new** — same |
| `terraform/backend.hcl.example` | **new** — committed template |
| `terraform/jenkins/backend.hcl.example` | **new** — committed template |
| `.gitignore` | add `backend.hcl` for both stacks (anchored per-directory, as the Jenkins tfvars rules had to be) |
| `terraform/versions.tf`, `terraform/jenkins/versions.tf` | `required_version` → `>= 1.11.0` |
| `scripts/deploy.sh` | run bootstrap, then `init -backend-config=backend.hcl` |
| `docs/deploy.md`, `docs/production-readiness.md`, `terraform/jenkins/README.md`, `CLAUDE.md` | document the backend, the bucket's protected status, and the new `init` form |

The test follows the established offline-stub pattern of `scripts/tests/test-sync-values.sh` and
`test-ci-guards.sh` (stub the AWS CLI through an env var), covering: idempotent re-run, name
derivation from `cluster_name` + account id, correct key per stack, and the absence of any hardcoded
region or account id in the generated output.

### 7. Migration order and gates

**Jenkins first** — it holds the 14 live resources and is the only state whose loss costs anything
today. Rehearsing on an empty state would prove nothing, since no resource mapping is exercised.

1. Copy `terraform/jenkins/terraform.tfstate` to a dated file **outside the repo**.
2. Run `scripts/bootstrap-tf-backend.sh`.
3. Add `backend.tf`; `terraform init -backend-config=backend.hcl -migrate-state`; confirm.
4. **Gate A** — `terraform state list` returns the same 14 addresses.
5. **Gate B** — `terraform plan -var-file=jenkins.tfvars` reports **"No changes"**.
6. **Gate C** — the object exists in S3; a second plan takes and releases the lock cleanly.
7. Repeat for the main stack.

**The two stacks have different acceptance tests, and applying the wrong one hides a real failure.**
Gate B is the meaningful check: "No changes" proves every resource in the moved state still maps to
its live counterpart. It is **inapplicable to the main stack**, whose state is empty — a plan there
correctly reports ~112 resources to create, which reads like a catastrophe and is not one. The main
stack's acceptance is Gate A (empty list) plus a successful `init`; its real proof arrives when
project C applies against the remote backend.

### 8. Rollback

Local state files are left in place and untouched until both stacks pass their gates. To revert:
delete `backend.tf` and run `terraform init -migrate-state` in the reverse direction, or restore the
copy from step 1. No AWS resource is created, modified or destroyed at any point in this migration,
so there is nothing to roll back beyond the state's location.

---

## Verification

- `scripts/tests/test-bootstrap-backend.sh` passes offline.
- Bootstrap script re-run twice; second run reports no changes and exits 0.
- Jenkins stack: Gates A, B, C.
- Main stack: Gate A + successful `init`.
- `terraform fmt -recursive` clean; `terraform validate` passes in both stacks.
- Bucket inspected: versioning `Enabled`, encryption present, all four public-access blocks `true`,
  lifecycle rule present, non-TLS request denied.
- Deliberate concurrency check: a second `terraform plan` during a held lock is refused.

---

## Risks

| Risk | Mitigation |
|---|---|
| Migration corrupts or loses the Jenkins state | Copy taken outside the repo first; Gate B proves the mapping survived; local file retained |
| Bucket deleted later, taking both states | Versioning on; bucket owned by no stack and excluded from `destroy.sh`; documented as protected |
| `backend.hcl` missing on a fresh clone → confusing `init` error | `deploy.sh` runs the bootstrap script itself; `.example` files committed; documented in `docs/deploy.md` |
| State in S3 contains secrets (RDS password) | SSE-S3 encryption, TLS-only policy, full public-access block. A customer-managed KMS key would add per-principal key control; deferred as disproportionate for a single-operator account with no other principals |
| `required_version` floor raised to 1.11.0 | Accepted; the deprecated alternative would require this migration again later |
| Operator forgets `-backend-config` on a manual `init` | Terraform errors on incomplete backend config rather than silently using local state; `deploy.sh` is the supported path |

---

## Relationship to the other pending work

This is project **B** of four agreed on 2026-07-21, ordered so that the unrecoverable-failure-mode
item lands first and while it is cheapest:

- **B — remote state** (this document)
- **A — JCasC for the Jenkins host** (`docs/production-readiness.md` §7)
- **C — redeploy + RDS durability + WAF** (§3, §2)
- **D — retire `terraform/github-oidc.tf`**, the GitHub Actions rollback path. Not a project; a
  single irreversible deletion, gated on a green Jenkins build against the redeployed cluster in C.
