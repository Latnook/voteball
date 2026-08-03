# Raw evidence captures

Unedited command output backing the claims in
[`../live-cluster-snapshot.md`](../live-cluster-snapshot.md). That file carries readable, trimmed
excerpts; these are the full captures, so a reader can check a summary rather than take it on trust.

**These are dated evidence and are never "corrected".** The cluster they describe is destroyed and
rebuilt regularly, which regenerates every pod name, ALB hostname, ACM certificate and WAF id. A
value here that no longer resolves is the file working as intended. When the system changes, capture
a **new** dated set — never edit an old one to match.

Re-capture with **[`../../../scripts/capture-evidence.sh`](../../../scripts/capture-evidence.sh)**:

```bash
./scripts/capture-evidence.sh                 # everything, including the pod-restart demo
./scripts/capture-evidence.sh --no-restart    # skip the demo that deletes a pod
./scripts/capture-evidence.sh --only-restart  # re-take just the pod-restart poll
```

## 2026-08-04 — the current system, and a clean first-run rebuild

Captured on EKS **1.36**, Jenkins in-cluster, across one `destroy.sh` → `deploy.sh` cycle:
**132 resources destroyed** in 12m09s, **121 created** in 17m21s. **Vote totals identical across it:
18 previous-party, 23 upcoming.** Everything else — certificate, ALB, cluster, node IPs, every pod
name, and this time the deploy key and webhook too — is new.

**Unlike the 2026-08-03 cycle below, this one completed on the first invocation**, because the two
faults that cycle exposed were fixed in between. This set exists to show they stay fixed:

- **The deploy-key race.** On 2026-08-03, `deploy.sh` pushed `values.yaml` at step 9 while the deploy
  key was not registered until step 11b — so the webhook fired and the build died on
  `Permission denied (publickey)` 21 seconds before the key existed on GitHub. Registration moved to
  **step 3c**; `2026-08-04-deploy-steps.txt` shows it registering a genuinely new key
  (`removed stale key … / registered key …`) before the cluster is even built, and the probe running
  separately at 11b once Jenkins can answer it.
- **The empty-changelog skip (G3b).** The first build on a freshly recreated controller has no
  changelog, which `changeset 'services/**'` cannot distinguish from "nothing changed" — so on
  2026-08-03 it skipped build, scan, push and tag bump and reported **SUCCESS** while ECR gained
  nothing. Build 1 here logs `First time build. Skipping changelog.` and **builds anyway**, then
  build 2 — the pipeline's own `[skip ci]` commit — is correctly aborted `NOT_BUILT` by the Guard.
  That pair is the whole invariant: never silently skip, never loop.

The first build after a rebuild also logs `failed to configure registry cache importer:
…/voteball-buildcache:… not found` four times. That is expected and non-fatal — ECR is destroyed with
the stack, so the cache tags do not exist yet and BuildKit proceeds without them.

> **A footnote on build 3, because it is instructive.** The commit that added this file was
> documentation only and should have been skipped by the path filter — but it was aborted earlier
> than that, by the Guard, because its message *described* the pipeline's marker commit and therefore
> contained the marker text. The Guard matches the message, not the intent, and deliberately fails
> safe toward skipping. Right outcome, different mechanism; see the G3 row in `docs/cicd.md`.

| File | What it is |
|---|---|
| `2026-08-04-destroy-steps.txt` | Six ordered teardown steps, `Destroy complete! Resources: 132 destroyed.` |
| `2026-08-04-deploy-steps.txt` | One clean invocation, ending `Deploy complete.` / `DEPLOY_EXIT=0` |
| `2026-08-04-pre-teardown-kubectl.txt` | The eight required `kubectl` outputs before teardown — nodes, namespaces, pods, deployments, services, ingress, `describe pod`, and backend logs |
| `2026-08-04-pre-teardown-demos.txt` | HTTPS + ACM certificate, HTTP→HTTPS redirect, `/api/options` and `/api/results?by=all`, the S3 backup Job writing via IRSA, the ServiceAccount role table, the NetworkPolicy probe **with its control**, SNS counters, and the shipped alert rules |
| `2026-08-04-pre-teardown-pod-restart-poll.txt` | **123** probes, all 200, across a `kubectl delete pod` |
| `2026-08-04-post-rebuild-kubectl.txt` | The same eight outputs from the **rebuilt** cluster — every node IP and pod name is new |
| `2026-08-04-post-rebuild-demos.txt` | The same demos re-run after the rebuild — new ACM certificate, identical vote totals |
| `2026-08-04-post-rebuild-pod-restart-poll.txt` | **124** probes, all 200, on the rebuilt cluster |
| `2026-08-04-ci-builds.txt` | All five builds on the rebuilt controller, with each one's changelog size and decision points — the checkable form of the G3b claims above |

## 2026-08-03 — the previous cycle, kept because it recorded two real faults

Captured on EKS **1.36** with Jenkins running in-cluster (namespace `ci`) — the same architecture as
the 2026-08-04 set above, which supersedes this one as the current-state capture. **This set is kept
deliberately**: it is the record of the deploy-key race and the empty-changelog skip actually
happening, and a fix is only meaningful next to evidence of what it fixes. Two matched halves either
side of one `destroy.sh` → `deploy.sh` cycle:
**132 resources destroyed**, then rebuilt, with the database restored from the automatic final
snapshot. **The vote totals are identical across it: 18 previous-party, 23 upcoming.** Everything
else — certificate, ALB, cluster, node IPs, every pod name — is new.

**The rebuild did not succeed on the first run, and the log is not edited to hide that.**
`2026-08-03-deploy-steps.txt` contains all three invocations in order:

1. The full apply died ~13 minutes in on
   `Error: namespaces is forbidden: User ".../cli-admin" cannot create resource "namespaces"`.
   `kubernetes_namespace.ci` is the first kubernetes-provider resource to touch a brand-new cluster
   (everything else arrives via `helm_release`, later in the graph), so it is the one resource that
   can lose a race with EKS access-entry propagation. Fixed permanently by a `depends_on` in
   `terraform/addon-jenkins.tf`.
2. The re-run then died at step 5 on
   `The image tag '4993a70' already exists ... and cannot be overwritten because the tag is immutable`.
   That was a **real recoverability bug**: `build-push-ecr.sh` pushed unconditionally, so once any
   image had been pushed, `deploy.sh` could never be re-run to completion. Fixed by reusing CI's
   G1 check (`scripts/ci/images-exist.sh`) to skip tags already present.
3. The third run completed end to end — `Deploy complete.` / `DEPLOY_EXIT=0`.

A rebuild that only ever runs cleanly cannot demonstrate that it recovers. This one did.

| File | What it is |
|---|---|
| `2026-08-03-destroy-steps.txt` | The six ordered teardown steps and `Destroy complete! Resources: 132 destroyed.` |
| `2026-08-03-deploy-steps.txt` | All three `deploy.sh` invocations above, ending `Deploy complete.` / `DEPLOY_EXIT=0` |
| `2026-08-03-post-rebuild-kubectl.txt` | The eight required outputs from the **rebuilt** cluster |
| `2026-08-03-post-rebuild-demos.txt` | The same demos re-run after the rebuild — new ACM certificate, same vote totals |
| `2026-08-03-post-rebuild-pod-restart-poll.txt` | **124** probes, **all 200**, across a `kubectl delete pod` on the rebuilt cluster |
| `2026-08-03-pre-teardown-kubectl.txt` | All eight required `kubectl` outputs — nodes, namespaces, pods, deployments, services, ingress, `describe pod` and `logs` for a backend replica |
| `2026-08-03-pre-teardown-demos.txt` | HTTPS + ACM certificate, HTTP→HTTPS redirect, `/api/options` and `/api/results?by=all`, the S3 backup Job writing an object via IRSA, the ServiceAccount role table, the NetworkPolicy probe **with its control**, SNS topic + 7-day delivery counters, and the shipped alert rules |
| `2026-08-03-pre-teardown-ci-rollout-poll.txt` | 2,218 probes, **all 200**, spanning 21:11:34→21:14:10 — a window that happened to contain both a CI-driven rolling update of all three Deployments *and* a deliberate `kubectl delete pod`. Unplanned and better than the planned run: zero failed requests while every pod in the namespace was replaced |
| `2026-08-03-pre-teardown-pod-restart-poll.txt` | The deliberate version: **127** probes, **all 200**, over 72s — 15s of baseline, a `kubectl delete pod` of a frontend replica, the rollout, and 45s of tail. The baseline and tail are the point: the replacement can be Ready in ~12 seconds, and a capture that starts at the delete and stops at "successfully rolled out" is 18 probes long, which cannot distinguish "nothing failed" from "we barely looked" |

**Why the poll is throttled to two requests a second.** An unthrottled `while :; do curl` loop runs
at roughly 850 requests/minute, and `terraform/waf.tf`'s `RateLimitSiteWide` rule blocks an IP at
2,000 requests per 5 minutes **across every path**, not just `/api/vote`. Two back-to-back captures
crossed that ceiling and the next 558 probes all returned `403` from `awselb` — which reads exactly
like "the site went down during the restart" when it means "the site defended itself against the
measurement". CloudWatch settled it: `voteball-rate-sitewide` blocked 1,299 requests in that window
while `voteball-rate-vote` blocked none. The `sleep 0.5` in the poller is load-bearing.

## 2026-07-27 — a destroy → rebuild cycle

Two matched sets captured either side of one deliberate `destroy.sh` → `deploy.sh` cycle. Comparing
them is the point: the vote count is identical across a full teardown and rebuild, while the
certificate, ALB, pod names and cluster are all new. **This set predates the Jenkins-on-EKS migration
and the 1.34→1.36 upgrade** — it shows no `ci` namespace and a 112-resource stack, and that is
correct for its date.

| File | What it is |
|---|---|
| `2026-07-27-pre-teardown-kubectl.txt` | All eight required `kubectl` outputs, untrimmed — including the complete `describe pod` for a backend replica |
| `2026-07-27-pre-teardown-demos.txt` | The demo runs: HTTPS + certificate, `/api/options` and `/api/results`, the S3 backup job, ServiceAccount IRSA roles, SNS delivery counters, alert rules, and the NetworkPolicy probe with its control |
| `2026-07-27-pod-restart-poll.txt` | 1,050 timestamped HTTP status probes spanning a deliberate `kubectl delete pod` of a frontend replica through to the replacement reaching `1/1 Ready` |
| `2026-07-27-destroy-steps.txt` | The six ordered teardown steps and `Destroy complete! Resources: 112 destroyed.` |
| `2026-07-27-deploy-steps.txt` | The eight ordered rebuild steps and `Apply complete! Resources: 112 added, 0 changed, 0 destroyed.` |
| `2026-07-27-post-rebuild-kubectl.txt` | The same eight outputs, from the rebuilt cluster |
| `2026-07-27-post-rebuild-demos.txt` | The same demos, re-run after the rebuild |
| `2026-07-27-post-rebuild-pod-restart-poll.txt` | 700 probes across a pod deletion on the rebuilt cluster |

## Checking the pod-restart claim yourself

The claim is "the site stayed up across a pod restart". Verify it rather than believe it:

```bash
wc -l docs/eks/evidence/2026-08-03-pre-teardown-ci-rollout-poll.txt          # 2218 probes
awk '$2!=200' docs/eks/evidence/2026-08-03-pre-teardown-ci-rollout-poll.txt  # no output == no failed request
```

Two frontend replicas plus a PodDisruptionBudget are what make losing one invisible.

## No credentials here

These captures are scanned before being committed — `capture-evidence.sh` aborts rather than write a
file in which `DB_PASS`, `ADMIN_PASSWORD_HASH` or `ADMIN_SESSION_SECRET` carries a value. `describe
pod` renders environment variable **names** only: the values arrive via `envFrom` referencing a
ConfigMap and a Secret, so they are never printed. The `app-secret` contents (which hold
`ADMIN_PASSWORD_HASH`, not a password) appear nowhere in this directory.
