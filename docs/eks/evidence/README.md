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

## 2026-08-03 — the current system, across a destroy → rebuild cycle

Captured on EKS **1.36** with Jenkins running in-cluster (namespace `ci`) — the architecture the repo
describes today. Two matched halves either side of one `destroy.sh` → `deploy.sh` cycle:
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
