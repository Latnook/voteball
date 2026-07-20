# Maintenance

`docs/production-readiness.md` covers *"is this robust enough"*. This covers *"will it still work in
six months"* — the things that rot on their own while nobody touches the code.

Verified against the repo on 2026-07-20.

---

## The one with a deadline: EKS 1.34

```
Standard support ends   2026-12-02
Runway from 2026-07-20  ~134 days (about 4 months)
```

After that date the cluster silently moves to **extended support at 5× the control-plane price**
(≈$0.10/hr → ≈$0.60/hr, roughly **+$360/month** for a cluster that otherwise costs ~$200/month total).
Nothing breaks; the bill just quadruples, which is the worst kind of failure because nothing alerts.

**Action:** bump `cluster_version` in `terraform/voteball.tfvars` before December. Check the window
first — `aws eks describe-cluster-versions --region <region>` — and pick a version still in *standard*
support. Expect to bump some add-on chart versions with it.

> This is the single highest-value item on this page: it is dated, costed, and silent.

---

## Version pins that drift

Nine Helm charts and the EKS add-ons are pinned, all verified on 2026-07-19:

| Chart | Pinned |
|---|---|
| ArgoCD | 10.1.4 |
| AWS Load Balancer Controller | 3.4.2 |
| kube-prometheus-stack | 87.17.0 |
| External Secrets Operator | 2.8.0 |
| Cluster Autoscaler | 9.58.0 |
| external-dns | 1.21.1 |
| metrics-server | 3.13.1 |
| Node Termination Handler | 0.21.0 |

Pinning is correct — unpinned charts turn every `terraform apply` into a surprise. But pins are a
promise to revisit them. Community charts move fast and old versions stop supporting newer Kubernetes,
so these need bumping *with* the EKS upgrade, not after it.

**Check with:** `helm search repo <chart> --versions | head`.

**Provider pins** (`terraform/versions.tf`): `aws ~> 5.0` is capped by `terraform-aws-modules/eks`
v20, which requires `< 6.0`. Moving to AWS provider v6 means upgrading that module first. `helm ~> 2.17`
is deliberate — v3 changed the nested `kubernetes {}` block syntax used in `providers-k8s.tf`.

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

**Suggested:** add `.github/dependabot.yml` covering `pip` (both services), `docker`, and
`github-actions`. Grouped weekly PRs are enough at this scale — and CI already builds, scans and
tests every PR, so a bad bump fails loudly before it reaches the cluster.

---

## GitHub Actions deprecation, already warning

Every CI run currently prints:

> Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on
> Node.js 24: `actions/checkout@v4`, `aws-actions/configure-aws-credentials@v4`

It is a warning today and will become a failure. Bump those actions when v5 equivalents are
available. `aquasec/trivy` is pinned at `0.58.1` — its vulnerability database updates on every run,
but the scanner binary itself ages.

---

## Routine housekeeping

- **RDS snapshots accumulate** — one per teardown (six by the end of 2026-07-20). Only the newest is
  ever used by `find-latest-snapshot.sh`. Prune to the most recent N.
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
| Monthly | Skim Dependabot PRs; prune old RDS snapshots |
| Quarterly | Bump add-on chart versions; check the EKS support window |
| **Before 2026-12-02** | **Upgrade EKS off 1.34 or start paying 5×** |
| When torn down | Nothing rots — the cheapest maintenance posture is not running it |

That last row is worth stating plainly: this stack is designed to be destroyed and rebuilt on demand,
and `./scripts/destroy.sh` preserves the data in a snapshot. If it is not being demoed, the correct
maintenance action is to tear it down.
