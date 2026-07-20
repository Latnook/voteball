# Deployment hardening: seamless apply/destroy cycles

**Date:** 2026-07-20
**Status:** approved, pending implementation

> **Historical record.** CI moved from GitHub Actions to Jenkins on 2026-07-20; every
> `.github/workflows/ci.yml` reference below describes the pipeline as it was at the time. See
> [`2026-07-20-jenkins-migration-design.md`](2026-07-20-jenkins-migration-design.md) and
> [`../cicd.md`](../cicd.md) for the current pipeline.

## Problem

The EKS deploy/destroy cycle is not repeatable. Two failures on the 2026-07-20 rebuild
(`kube-prometheus-stack` rejected by the ALB webhook; Secrets Manager refusing to recreate a secret
still in its deletion window) were fixed in `9d16bcf`, and two more (`image.tag` and
`ingress.certificateArn` in `charts/voteball/values.yaml` both stale) in `b9779cf`. All four were
symptoms of the same class of defect: **environment-specific identifiers are copied by hand, and the
ordering constraints between add-ons are implicit.**

An audit of the full path surfaced seven remaining hazards.

### H1 — `values.yaml` carries infra IDs that change every rebuild

| Field | Changes on rebuild? | In `docs/deploy.md`? | Terraform output |
|---|---|---|---|
| `image.tag` | every commit | yes (step 4) | n/a (git SHA) |
| `config.DB_HOST` | yes (new RDS instance) | yes (step 5) | `rds_endpoint` |
| `ingress.certificateArn` | yes (new ACM cert) | **no — undocumented** | `acm_certificate_arn` |

Every one of these already has a Terraform output that nothing consumes. The undocumented cert row is
what broke the ALB on 2026-07-20 (`CertificateNotFound` → `FailedDeployModel`).

### H2 — the ALB service-mutator webhook races every add-on

The AWS Load Balancer Controller installs a cluster-wide mutating webhook on **Services** with
`failurePolicy: Fail`. Any add-on creating a Service before the controller's pods are Ready fails with
`no endpoints available for service "aws-load-balancer-webhook-service"`. Only `aws_eks_addon.cloudwatch`
carried a `depends_on`; ESO, ArgoCD, external-dns, autoscaler, metrics-server and kube-prometheus-stack
all create Services and all passed by timing luck.

### H3 — `scripts/find-latest-snapshot.sh` targets the retired k3s stack

`TF_DIR` resolves to `terraform/` (retired; the EKS stack never reads it) and the query uses
`--db-instance-identifier voteball-db` (the k3s instance; EKS is `voteball-eks-db`). The script silently
does nothing useful for the live stack.

### H4 — the DB snapshot is a single point of failure

`db_snapshot_identifier` is pinned to one literal ID, `skip_final_snapshot = true` means destroy creates
no replacement, and exactly **one** manual snapshot remains in the account. If it is ever pruned, every
future `apply` hard-fails with no recovery path.

### H5 — ArgoCD is never bootstrapped

`docs/deploy.md` has no `kubectl apply -f argocd/voteball-application.yaml` step, so a rebuilt cluster has
no Application. CLAUDE.md's "changes reach the cluster by committing to `master`" is therefore false on a
fresh cluster — verified true on the 2026-07-20 rebuild.

### H6 — the documented destroy order is wrong

`docs/deploy.md` says `helm uninstall` → `terraform destroy`. With ArgoCD running `prune: true` and
`selfHeal: true`, ArgoCD recreates the app after the uninstall. CLAUDE.md has the correct order; the file
the runbook points at does not.

### H7 — destroy leaves stale DNS

external-dns runs `policy=upsert-only`, so `voteball.latnook.com` keeps resolving to a de-provisioned ALB
between teardown and next deploy.

### H8 — orphaned VPC CNI network interfaces block subnet deletion *(found during verification)*

When nodes terminate, the AWS VPC CNI can leave **detached** (`status=available`) `aws-K8S-*` network
interfaces behind. Terraform then retries `DeleteSubnet` against a `DependencyViolation` until it times
out. On the 2026-07-20 teardown this stalled the destroy for ~10 minutes; deleting the single orphaned
interface by hand let the subnet drop within seconds.

### H9 — ArgoCD bootstrapped before `values.yaml` is committed *(found during verification)*

ArgoCD deploys what is on `master`, not what is on disk. `deploy.sh` synced `values.yaml` (step 6) and
then created the Application (step 8) while the file was still uncommitted — so ArgoCD immediately
reverted the cluster to master's stale `image.tag`. After a rebuild that tag names an image absent from
the freshly-created ECR, so every pod went to `ImagePullBackOff` while the correct deploy was undone
underneath it. Observed on the 2026-07-20 rebuild.

## Non-goals

- No dev/prod split or multi-instance support (deliberate project constraint).
- No migration of `values.yaml` away from git — ArgoCD reads it from `master`; git stays the source of truth.
- No change to how secrets are handled; `seed-eks-secret.sh` and the ESO path are correct as-is.

## Design

### 1. `scripts/sync-values-from-tf.sh` — one command owns all drift

Reads Terraform outputs and rewrites the env-specific fields of `charts/voteball/values.yaml`:

| Field | Source |
|---|---|
| `config.DB_HOST` | `terraform -chdir=terraform output -raw rds_endpoint` |
| `ingress.certificateArn` | `... output -raw acm_certificate_arn` |
| `config.S3_BUCKET` | `... output -raw s3_bucket` |
| `backup.roleArn` | `... output -raw backup_role_arn` |
| `image.tag` | `git rev-parse --short HEAD`, overridable via `--tag <sha>` |

Implementation uses anchored `sed`, matching the technique already in `.github/workflows/ci.yml` — no new
tool dependencies (no `yq`).

A `--check` mode diffs live-vs-file and exits non-zero without writing, so the same script serves as a
preflight guard inside `deploy.sh`.

This replaces `docs/deploy.md` steps 4–5 and closes the undocumented cert gap (H1).

**Rejected alternative — ACM auto-discovery.** The AWS LB Controller can discover a cert matching the
Ingress host when the `certificate-arn` annotation is absent. Rejected: two ISSUED certs match
`voteball.latnook.com` (the exact cert, plus a `*.latnook.com` wildcard). Discovery would attach both, and
the wildcard is **not managed by this Terraform stack** — binding a cert whose lifecycle Terraform does not
control is a worse failure mode than the drift it removes.

### 2. Disable the service-mutator webhook (H2)

Set `enableServiceMutatorWebhook: false` on the `aws_load_balancer_controller` `helm_release`.

Per the chart's own documentation this webhook exists only to "make this controller the default for all new
services of type LoadBalancer." Voteball routes exclusively via Ingress→ALB and has **zero** Services of
type LoadBalancer, so the webhook provides no value while intercepting every Service creation
cluster-wide. Disabling it removes the race for all current *and future* add-ons.

The existing `depends_on` on `aws_eks_addon.cloudwatch` stays (harmless; documents the history). No further
`depends_on` edges are added — six ordering constraints to work around a webhook we don't need is the wrong
shape of fix.

### 3. Snapshot lifecycle becomes self-sustaining (H3, H4)

**`find-latest-snapshot.sh`:**
- `TF_DIR` → `terraform/`, writing `terraform/snapshot.auto.tfvars`.
- Search **both** the `voteball-eks-db` and legacy `voteball-db` lineages; newest `SnapshotCreateTime` wins.
- When no snapshot exists, write `db_snapshot_identifier = null` (fresh empty DB) instead of leaving the
  pinned literal to hard-fail.
- Correspondingly, `variables.tf`'s `db_snapshot_identifier` default changes from the pinned literal
  `voteball-db-final-20260719175321` to `null`, making the script the sole authority on which snapshot is
  restored. Leaving the literal default would reintroduce the hard-fail whenever the script is skipped.
- Preserve the existing distinction between "API call succeeded, found zero" and "API call failed" — the
  latter must still abort loudly rather than silently degrade to an empty DB.

**`database.tf`:** `skip_final_snapshot = false` with a `final_snapshot_identifier` derived from a
`time_static` resource, plus `lifecycle { ignore_changes = [final_snapshot_identifier] }` to avoid a
perpetual plan diff. This adds the `hashicorp/time` provider to `versions.tf`, so implementation requires
`terraform init -upgrade` before the first plan.

Consequence: every destroy leaves a restore point, removing the SPOF and making destroy→rebuild preserve
votes instead of discarding them. `docs/deploy.md`'s "votes cast on EKS are not saved" note must be updated
to match.

### 4. Clean DNS teardown (H7)

external-dns `policy` → `sync`. Combined with deleting the Ingress *before* `terraform destroy`,
external-dns removes its own A/AAAA/TXT records.

Blast radius (explicitly approved by the user): `sync` permits record **deletion** in the live
`latnook.com` zone. Bounded by `txtOwnerId=voteball` (ownership TXT) and `domainFilters=latnook.com`, so
only records external-dns created are eligible; apex `latnook.com` records are never touched.

### 6. Orphaned-ENI reaper (H8)

`destroy.sh` runs a background loop during `terraform destroy` that deletes network interfaces which are
**both** detached (`status=available`) **and** CNI-created (`Description` starts with `aws-K8S-`), scoped
to this stack's VPC. A detached CNI interface is garbage by definition; anything still in use reports
`status=in-use` and is never considered.

Reaping concurrently rather than retrying after failure is deliberate: Terraform takes 10–20 minutes to
give up on the subnet, so a retry-on-failure wrapper would still pay that stall every time. The
interfaces also only appear *during* destroy (as nodes terminate), so a pre-flight cleanup would find
nothing.

### 7. Commit before ArgoCD bootstrap (H9)

`deploy.sh` commits and pushes `values.yaml` immediately after syncing it, **before** creating the ArgoCD
Application. If the push fails, the bootstrap is skipped rather than handing the cluster to a source of
truth that would break it.

### 5. Ordered orchestrators (H5, H6)

Both scripts echo each step and **stop before `terraform apply`/`destroy`** for interactive confirmation —
they never run a billed or destructive Terraform operation unattended.

**`scripts/deploy.sh`:**
1. `find-latest-snapshot.sh`
2. `terraform apply` *(confirm)*
3. `seed-eks-secret.sh`
4. `aws eks update-kubeconfig`
5. `build-push-ecr.sh`
6. `sync-values-from-tf.sh`
7. `helm upgrade --install`
8. `kubectl apply -f argocd/voteball-application.yaml` ← the missing bootstrap

**`scripts/destroy.sh`:**
1. `kubectl delete -f argocd/voteball-application.yaml` (stops selfHeal fighting the teardown)
2. `kubectl delete ingress voteball -n devops-app`
3. Poll until the ALB de-provisions (leftover ENIs block VPC deletion)
4. `terraform destroy` *(confirm)*

Step 3 polls for the ALB's absence rather than sleeping a fixed interval.

`docs/deploy.md` is rewritten around these two commands, including the corrected destroy order and the
`terraform state rm` escape hatch for a `helm_release` that hangs on uninstall (currently only in
CLAUDE.md).

## Verification

Hardening changes to a deploy path can only be proven by exercising it. Acceptance is a full
`destroy.sh` → `deploy.sh` cycle from the current live cluster, asserting:

1. `terraform apply` completes with **zero** webhook errors (H2).
2. `values.yaml` needs **no** hand-editing; `sync-values-from-tf.sh --check` exits 0 post-deploy (H1).
3. `kubectl get application -n argocd` shows `voteball` Synced/Healthy (H5).
4. `https://voteball.latnook.com/api/options` returns 200 with seeded data.
5. After `destroy.sh`: `dig +short voteball.latnook.com @8.8.8.8` returns empty (H7), and a new final
   snapshot exists (H4).
6. Re-running `deploy.sh` restores the votes from that snapshot (H3, H4).

Static checks before the cycle: `terraform fmt -recursive`, `terraform validate`, `helm lint charts/voteball`,
`helm template` renders, and `bash -n` on every new/changed script.

## Risks

- **external-dns `sync`** — record deletion in a live zone. Mitigated by ownership TXT + domain filter;
  verified by checking apex records survive a destroy cycle.
- **`skip_final_snapshot = false`** — adds ~2–3 min to destroy and a small ongoing snapshot-storage cost.
- **Disabling the service-mutator webhook** — would matter only if the project later adds a Service of type
  `LoadBalancer`; it uses Ingress exclusively, and doing so would be an architectural change.
- **`sed`-based rewriting of `values.yaml`** — brittle if the file's formatting changes. Mitigated by
  anchored patterns and `--check` mode failing loudly rather than silently mis-writing.

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
