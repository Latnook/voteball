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

**Suggested:** add `.github/dependabot.yml` covering `pip` (both services) and `docker`. Grouped weekly
PRs are enough at this scale — and CI already builds and scans, so a bad bump fails loudly before it
reaches the cluster.

---

## The Jenkins build host needs its own upkeep

CI is Jenkins on a dedicated EC2 host (`terraform/jenkins/`, see `docs/cicd.md`). Unlike GitHub's hosted
runners, **this is a server you own**, so it ages like one. Nothing here is urgent; all of it is silent.

- **Jenkins core.** Jenkins publishes security advisories regularly and its own UI shows an update
  banner. Bump it with `sudo dnf update jenkins && sudo systemctl restart jenkins` over the SSH tunnel.
  There is no automation for this, and no alert — the host has no public UI, so nobody sees the banner
  unless they open the tunnel. Fold it into the quarterly pass.
- **Jenkins plugins.** Five are installed (Git, Pipeline, GitHub, Credentials Binding, SSH Agent); update
  them from *Manage Jenkins → Plugins → Updates*. Plugin updates are the more common source of
  advisories, and also of behaviour changes — the webhook-secret bug documented in `docs/cicd.md` was a
  quirk of github plugin **1.47.0** specifically, so read the changelog before and re-test the webhook
  after (a push should produce a delivery with HTTP 200, not 400).
- **`aquasec/trivy:0.58.1` is pinned in the `Jenkinsfile`.** The vulnerability *database* refreshes on
  every run, so scanning stays current, but the scanner *binary* ages and stops learning new detection
  formats. Pinning is deliberate — an unpinned scanner can turn a green pipeline red overnight with no
  change from you — but a pin is a promise to revisit it. Bump the tag, run one build with `FORCE_BUILD`,
  and confirm the app images still scan clean before relying on it.
- **The host's OS.** Amazon Linux 2023 does not patch itself. `sudo dnf update` when you are on the box
  anyway; Docker and Java updates want a `systemctl restart jenkins` afterwards.
- **Cheapest maintenance posture: stop the instance.** ~$37/month running, ~$6/month stopped, and all
  state persists on the EBS volume (see `docs/cicd.md`). Webhooks are discarded while it is stopped.
- **`buildDiscarder` keeps the last 20 builds** and `docker image prune -f` runs after every build, so the
  30 GB volume is bounded — but check `df -h` if builds ever start failing oddly.

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
| Quarterly | Bump add-on chart versions; check the EKS support window; update Jenkins core + plugins and the pinned `aquasec/trivy` tag |
| **Before 2026-12-02** | **Upgrade EKS off 1.34 or start paying 5×** |
| When torn down | Nothing rots — the cheapest maintenance posture is not running it |

That last row is worth stating plainly: this stack is designed to be destroyed and rebuilt on demand,
and `./scripts/destroy.sh` preserves the data in a snapshot. If it is not being demoed, the correct
maintenance action is to tear it down.

One caveat to it: **`./scripts/destroy.sh` does not touch `terraform/jenkins/`**, deliberately — a CI
server owned by the stack it builds for would lose its history on every rebuild cycle. So while the
application stack is down, the Jenkins host keeps running and keeps billing unless you stop it
separately. Stopping it is the right move; destroying it is not, and would also leave an orphaned 30 GB
volume behind (its root volume is `delete_on_termination = false` on purpose, because Jenkins'
credentials and job configuration live only there).
