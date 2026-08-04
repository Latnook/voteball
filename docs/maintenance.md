# Maintenance

`docs/production-readiness.md` covers *"is this robust enough"*. This covers *"will it still work in
six months"* — the things that rot on their own while nobody touches the code.

Verified against the repo on 2026-07-31; pinned-image list re-checked 2026-08-04.

---

## The one with a deadline: EKS 1.36

```
Standard support ends   2027-08-02
Runway from 2026-07-30  ~368 days (about 12 months)
```

> Upgraded 1.34 → 1.35 → 1.36 in place on 2026-07-30, two sequential applies (EKS cannot skip a
> minor). Control plane 7m29s then 6m49s; node roll 12m21s then 9m30s.
>
> **Downtime was measured, not assumed.** The site and `/api/results` were polled every 2s across
> the second hop: 488 samples over 17m50s, 487 fully clean. One sample at 19:05:59 showed a failed
> connection to `/` while `/api/results` returned 200 in the same instant — a single connection-level
> hiccup, not an outage (an outage fails both). Effective availability 99.8% of samples, no
> consecutive failures.
>
> **`cluster-autoscaler` knowingly trails at app v1.35.0**, and the reason is narrower than "no 1.36
> exists". Upstream *has* released CA 1.36.0/1.36.1 and the images are live
> (`registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.1` returns a manifest). What has not shipped
> is a **chart** packaging them — 9.59.0 is the newest and still pins `tag: v1.35.0`.
>
> **Resolved on 2026-07-30 by an `image.tag` override** — `addon-autoscaler.tf` pins
> `image.tag = v1.36.1` over the chart's v1.35.0 default, so the binary matches the cluster while the
> chart catches up.
>
> The risk taken was that the chart's ClusterRole and args are generated for 1.35, so a 1.36 binary
> could fail `forbidden` on any resource the chart does not grant. **It did not**: verified after
> apply with 0 `forbidden`/RBAC matches, 0 error-level lines, caches populated, and normal
> node evaluation (`Calculating unneeded nodes`, both nodes correctly skipped at min size).
> `client-go` is now v0.36.2 against a 1.36 API server — an exact match.
>
> **Revert** = delete the `image.tag` set block and re-apply; the chart default v1.35.0 is a supported
> N-1 configuration and ran clean here too. **Drop the override** once a chart ships app 1.36 —
> keeping it past that point pins the image against a chart that would otherwise manage it.
>
> Check with `helm search repo autoscaler/cluster-autoscaler --versions` and read the *app* column,
> not the chart column. They are independent axes: 9.54.0 through 9.59.0 are six chart releases all
> shipping the same app v1.35.0.

After that date the cluster silently moves to **extended support at 5× the control-plane price**
(≈$0.10/hr → ≈$0.60/hr, roughly **+$360/month** for a cluster that otherwise costs ~$290/month total).
Nothing breaks; the bill just quadruples, which is the worst kind of failure because nothing alerts.

**Action:** bump `cluster_version` in **`terraform/variables.tf`** before **2027-08-02**, then apply.
(The earlier 2026-12-02 deadline was 1.34's, and it was met by the 2026-07-30 upgrade above — don't
read "before December" anywhere; that instruction is retired.)

> **Not in `voteball.tfvars`** — that file is gitignored (`.gitignore:14`), so a value set there
> lives only on one laptop while the committed default stays behind, and the repo silently stops
> describing the running cluster. This page said "tfvars" until 2026-07-30; it was wrong.

Check the window first — `aws eks describe-cluster-versions --region <region>` — and pick a version
still in *standard* support. Expect to bump some add-on chart versions with it.

Two things that make this less of a one-liner than it looks:

- **Do not upgrade from the AWS console.** Terraform owns `cluster_version` (`terraform/eks.tf:10`).
  A console upgrade leaves the real cluster ahead of the config, so the next `terraform plan` tries
  to *downgrade* — which EKS rejects — and every later apply fails until you reconcile by hand.
- **EKS cannot skip a minor version.** 1.34 → 1.36 is two sequential applies, each upgrading the
  control plane and then rolling the node group. Bump the default one minor at a time and let each
  hop go ACTIVE before starting the next. (A *fresh* apply against no existing cluster has no such
  limit — it creates the pinned version directly.)
- **Upgrades are one-way.** There is no EKS downgrade. If a version misbehaves, recovery is
  destroy-and-rebuild from the RDS snapshot, not a rollback.

> This is the single highest-value item on this page: it is dated, costed, and silent.

---

## Version pins that drift

Eight Helm charts and the EKS add-ons are pinned, all re-verified against the repo on 2026-07-30
(the date each pin was last confirmed *latest*, which is the number that matters — a pin nobody has
re-checked is the one that has drifted):

| Chart | Pinned | Last confirmed latest |
|---|---|---|
| ArgoCD | 10.2.1 | 2026-07-30 |
| AWS Load Balancer Controller | 3.4.3 | 2026-07-30 |
| kube-prometheus-stack | 87.21.0 | 2026-07-30 |
| External Secrets Operator | 2.8.0 | 2026-07-30 |
| Cluster Autoscaler | 9.59.0 | 2026-07-30 |
| external-dns | 1.21.1 | 2026-07-30 |
| metrics-server | 3.13.1 | 2026-07-30 |
| Node Termination Handler | 0.21.0 | 2026-07-30 |

The two native **EKS add-ons** (`aws_eks_addon`, not `helm_release`) are not both pinned the same
way, and that asymmetry is worth stating plainly rather than leaving "the EKS add-ons are pinned"
implying otherwise:

| EKS add-on | `addon_version` | Status |
|---|---|---|
| `amazon-cloudwatch-observability` (`terraform/addon-cloudwatch.tf`) | `v6.3.0-eksbuild.1` | pinned — verified for K8s 1.34 via `aws eks describe-addon-versions` (2026-07-19) |
| `aws-efs-csi-driver` (`terraform/addon-efs.tf`) | *(none set)* | **not pinned — a known, deliberate gap, not an oversight.** Terraform tracks whatever AWS currently ships as default for the cluster's EKS version. Revisit if it starts drifting the way Cluster Autoscaler did above; until then it is one fewer version to carry through every EKS minor bump. |

**The mechanical check is `helm show chart <ref> --version <v>` and its `kubeVersion` field**, not the
release notes. On 2026-07-30 every one of the eight declared either no constraint or an open-ended
floor (`>= 1.16-0`, `>= 1.19.0-0`, `>=1.25.0-0`) — no upper bound excluded the target Kubernetes
version. That check takes a minute and is what makes an EKS bump boring.

The exception it will not catch is **Cluster Autoscaler**, which declares *no* `kubeVersion` at all
while being the one add-on whose app version tracks the Kubernetes minor. Read its `appVersion`
instead: `helm search repo autoscaler/cluster-autoscaler --versions` shows chart → app, and the app
minor should equal the cluster minor.

Pinning is correct — unpinned charts turn every `terraform apply` into a surprise. But pins are a
promise to revisit them. Community charts move fast and old versions stop supporting newer Kubernetes,
so these need bumping *with* the EKS upgrade, not after it.

**Check with:** `helm search repo <chart> --versions | head`.

**Terraform floor** (`terraform/versions.tf`): `required_version >= 1.11.0`, because the S3 backend uses
native `use_lockfile` locking rather than the deprecated `dynamodb_table` argument. Downgrading below
1.11 breaks `init`. There is only the one stack now — the separate Jenkins EC2 stack and its own
version floor were retired on 2026-07-31 when Jenkins moved in-cluster.

**Provider pins** (`terraform/versions.tf`): `aws ~> 5.0` is capped by `terraform-aws-modules/eks`
v20, which requires `< 6.0`. Moving to AWS provider v6 means upgrading that module first — that pair
is still outstanding, and it is also what would clear the `resolve_conflicts` deprecation warning
that appears in every plan.

`helm` was moved **2.17 → ~> 3.0 (3.2.0) on 2026-07-30**. v3 rebuilt the provider on the Plugin
Framework, which turned blocks into attributes: `kubernetes {}` → `kubernetes = {}` in
`providers-k8s.tf`, and all 25 `set {}` blocks → `set = [{...}]` lists across the six add-on files.
**Do not reintroduce block syntax** — it fails `validate` against the v3 schema. Note the `kubernetes`
provider is still SDKv2 (`~> 2.31`) and keeps block syntax, so the two provider blocks in
`providers-k8s.tf` look nearly identical and are deliberately different.

The migration was **in place**: plan and apply both reported `0 added, 8 changed, 0 destroyed`, the
diff was purely state reshaping (`set`/`set_list`/`set_sensitive`/`postrender` emptied, a new
`upgrade_install` default), and **no pod restarted** — verified by pod start times predating the
apply by half an hour, while Helm revisions incremented. A Helm upgrade rendering identical manifests
does not roll a workload; only a changed pod template does.

**Known chart deprecation, not yet addressed:** the external-dns chart warns during plan that
`set { name = "provider", value = "aws" }` is the legacy form and that newer chart versions want a
structured `provider: {name: aws}` object. Harmless today; fix it *with* the next external-dns chart
bump, not before, so the new syntax is validated against a chart that actually expects it.

---

## The Trivy gate will fail CI without you changing anything

CI **blocks** on `CRITICAL`/`HIGH` fixable vulnerabilities in the three app images. Base images are
floating tags (`python:3.12-slim`, `nginxinc/nginx-unprivileged:alpine`, `postgres:17-alpine`), not
digest-pinned.

That combination means: **a CVE disclosed in a base image can fail your next unrelated push.** You
change a CSS file, CI fails on a Python CVE you have never heard of. This is the most likely way
maintenance surprises you, and it is working as designed — the gate exists to stop vulnerable images
reaching production.

When it happens:
1. Rebuild — floating tags mean a fresh pull often already contains the fix.
2. If upstream has no fix yet, `--ignore-unfixed` is already set, so only *fixable* findings block.
3. As a last resort, pin the specific CVE in a `.trivyignore` **with an expiry note** — never widen the
   severity gate.

The `backup` image is deliberately scanned report-only (third-party base, upstream Go CVEs outside
this project's control).

---

## Nothing automates dependency updates

There is no Dependabot or Renovate config. Python dependencies are exact-pinned
(`flask==3.1.3`, `gunicorn==23.0.0`, `boto3==1.42.85`, …) which is right for reproducibility, but
means they only move when someone moves them.

**Dependabot is a poor fit for this repo, and that is a workflow fact rather than a gap.** It only ever
proposes changes as **pull requests**, and this is a single-maintainer repo that commits directly to
`master` and runs a single-branch Pipeline job (`triggers { githubPush() }`) — nothing builds a PR, so
a Dependabot PR would sit unbuilt and unscanned, and a bad bump would still land on `master` before
anything tested it. Adopting it would mean adopting a PR workflow first.

**What actually fits here:** a periodic manual sweep, which the cadence table below schedules. The
useful commands are `pip list --outdated` inside each service's venv, and rebuilding the images —
the base tags float, so `docker build --pull` alone picks up base-image security fixes, and the Trivy
gate then blocks the push if anything CRITICAL/HIGH is still fixable. That gives most of Dependabot's
protection on the container side without a PR queue.

---

## Jenkins needs its own upkeep, even though it now lives in the cluster

CI is Jenkins in the `ci` namespace, installed by Terraform (`terraform/addon-jenkins.tf`, see
`docs/cicd.md`). Moving it in-cluster on 2026-07-31 removed the OS-patching and AMI-churn maintenance an
EC2 host needed, but two things still age on their own schedule and nothing alerts on either:

- **The Jenkins controller image.** Plugins are baked in at build time
  (`ci/jenkins/Dockerfile`, `ci/jenkins/plugins.txt` — 8 top-level entries, dependencies resolved
  automatically), pushed to ECR as `<cluster_name>-jenkins`, and referenced by a pinned tag in
  `terraform/voteball.tfvars` (`jenkins_image_tag`). This trades the EC2 host's "always current, ages
  invisibly" plugin set for an explicit, reproducible one — but that means **it never updates itself.**
  Rebuild it deliberately: bump `plugins.txt` if needed, run
  `./scripts/build-push-ecr.sh jenkins <new-tag>`, update `jenkins_image_tag`, `terraform apply`. Fold
  this into the quarterly pass; `jenkins-plugin-cli --list` output at build time belongs in any bug
  report.

  Plugin updates are the most common source of both security advisories and behaviour changes. After
  bumping the plugin set, **re-test the webhook with a SHA-256 signature** — signed should give `200`,
  unsigned `400`.
- **`moby/buildkit:v0.19.0-rootless`, `aquasec/trivy:0.58.1`, `quay.io/skopeo/stable:v1.17.0`,
  `amazon/aws-cli:2.22.0`, `python:3.12-slim` (lint/test), `postgres:16-alpine` (ephemeral test DB,
  not the app's own `postgres:17-alpine` base image) and `hadolint/hadolint:2.12.0-alpine`** are
  pinned in `ci/jenkins/jenkins.yaml`'s `voteball-build` agent pod template (`application-ci`);
  `alpine/k8s:1.31.3` and `quay.io/argoproj/argocd:v3.4.5` (matched to the
  running ArgoCD server's app version, not just any tag) are pinned in the `voteball-deploy` template
  (`application-cd`). The Trivy vulnerability *database* refreshes on every run via `--db-repository`,
  so scanning stays current, but every pinned binary ages and stops learning new formats/APIs. Pinning
  is deliberate — an unpinned image can turn a green pipeline red (or, worse, silently less strict)
  overnight with no change from you — but each pin is a promise to revisit it. Bump one, run a build
  with `FORCE_BUILD` (`application-ci`) or a manual `application-cd` run against a known-good tag,
  confirm nothing regressed before relying on it. Bumping the `argocd` CLI pin specifically also needs
  checking it still matches the server's chart version (`terraform/addon-argocd.tf`) — a client ahead
  of the server risks talking a gRPC dialect the server doesn't understand.
- **`buildDiscarder` keeps the last 20 builds, on both jobs.** There is no equivalent of "check `df -h`"
  any more — a pod agent is destroyed after every build, so there is no persistent disk to fill. Build
  history itself now **survives a routine Spot reclaim** (the node group is 100% Spot, reclaimed
  roughly once a day): `JENKINS_HOME` is a PersistentVolumeClaim on EFS, not an `emptyDir`, since the
  2026-08-04 CI/CD split — see `docs/cicd.md` for the storage-survival table across a reclaim, a
  release removal, and a full teardown. Nothing to maintain here; it is a designed-in property, not
  drift.

---

## Routine housekeeping

- **RDS snapshots accumulate** — one per teardown (**nine** in the account as of 2026-07-29). Only the
  newest is ever used by `find-latest-snapshot.sh`. Prune to the most recent N. When you do, sort by
  `SnapshotCreateTime` and **never by the identifier** — the name embeds the *deploy* date, so the
  newest snapshot can carry the oldest-looking name (`voteball-eks-db-final-20260722065933` was
  created 2026-07-27).
- **CloudWatch log groups have no retention policy** — they grow and bill indefinitely. Set 14–30 days.
- **`values.yaml` churn** — every deploy and every CI build commits to `master`. Harmless, but the
  history is noisy; that is the cost of the GitOps model.
- **ACM certificate** renews automatically (DNS-validated). No action — this replaced the k3s certbot
  setup precisely because that one *did* need babysitting and hit rate limits.

---

## A realistic cadence

| When | Do |
|---|---|
| Each deploy | Watch for the Trivy gate failing on new CVEs |
| Monthly | Check for dependency updates **by hand** — nothing raises them for you (see above); prune old RDS snapshots |
| Quarterly | Bump add-on chart versions (Jenkins included); check the EKS support window; rebuild the Jenkins controller image and bump the pinned `buildkit`/`trivy`/`skopeo`/`aws-cli` tags in `ci/jenkins/jenkins.yaml` |
| **Before 2027-08-02** | **Upgrade EKS off 1.36 or start paying 5×** (the 2026-12-02 deadline was met — 1.34 → 1.36 on 2026-07-30, see above) |
| When torn down | Nothing rots — the cheapest maintenance posture is not running it |

That last row is worth stating plainly: this stack is designed to be destroyed and rebuilt on demand,
and `./scripts/destroy.sh` preserves the data in a snapshot. If it is not being demoed, the correct
maintenance action is to tear it down.

The old caveat to this — that a separately-owned Jenkins EC2 host kept running and billing after
`./scripts/destroy.sh`, and had to be stopped by hand — no longer applies. Jenkins is part of the same
stack as the app now (namespace `ci`, installed by the same `terraform apply`), so `destroy.sh` takes it
down too, with nothing left running to bill for and nothing orphaned to clean up by hand.

**But "nothing is lost" is too strong, and the exception costs you a working pipeline.** Its
configuration survives — that lives in git as JCasC. Its **credentials do not.**
`terraform/secrets.tf` sets `recovery_window_in_days = 0` on `voteball/jenkins`, so the secret is
*hard-deleted* by `terraform destroy` (deliberately: a recovery window would block recreating a
same-named secret on the next apply). The next `deploy.sh` mints a **fresh GitHub deploy key and a
fresh webhook secret**, and GitHub still holds the old ones — until both are re-registered by hand,
the webhook is rejected and the pipeline's final `git push` is denied, on a cluster that otherwise
looks entirely healthy. See `docs/cicd.md`, "First-time setup runbook", steps 1 and 4. Build history
is the part that is genuinely disposable by design.
