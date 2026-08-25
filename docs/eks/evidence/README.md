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

The Task 4 (Jenkins CI/CD) captures have their own script,
**[`../../../scripts/capture-task4-evidence.sh`](../../../scripts/capture-task4-evidence.sh)** — the
`task4-*` files were hand-run for the 2026-08-04 set and had drifted badly by 2026-08-17 (see that
section below). Static captures are read-only; nothing in it triggers a build or pushes a commit.

```bash
./scripts/capture-task4-evidence.sh                                   # all static captures
./scripts/capture-task4-evidence.sh --build-log application-ci 3      # one build's console log
./scripts/capture-task4-evidence.sh --build-log application-cd 2 rollback-broken-deploy
```

It refuses to write a console log that appears to contain a credential — a runtime-fetched secret in
argument position gets printed by Jenkins' `set -x`, which put a live ECR token into committed
evidence on 2026-08-04.

## 2026-08-24 — Observability re-captured, and a defect it found

The observability evidence had been hand-run on 2026-08-18 and was, by this date, the oldest set in
this directory while describing the newest work. It now has a script:

```bash
./scripts/capture-observability-evidence.sh                      # read-only steady-state capture
./scripts/capture-observability-evidence.sh --label post-dns-fix # suffix the filename
```

It is read-only — no pod deleted, no quota applied, nothing rolled. The failure **drills** are
deliberately not automated: they break production on purpose and belong to a human who is watching.

| File | What it holds |
|---|---|
| [`2026-08-24-observability.txt`](2026-08-24-observability.txt) | The first capture — which caught the cluster in the broken state below. 29/29 targets up, 234/234 rules healthy, and `voteball:availability:ratio5m` reporting a confident `1` over nothing. |
| [`2026-08-24-canary-dns-negative-cache.txt`](2026-08-24-canary-dns-negative-cache.txt) | The incident: diagnosis, root cause, repair and proof. |
| [`2026-08-24-observability-post-dns-fix.txt`](2026-08-24-observability-post-dns-fix.txt) | The same capture after the fix, with a real denominator under the SLIs. |
| [`2026-08-24-grafana-application-overview.png`](2026-08-24-grafana-application-overview.png) | Application Overview as rendered, filtered by Service/Pod/Release. |
| [`2026-08-24-grafana-kubernetes-cluster.png`](2026-08-24-grafana-kubernetes-cluster.png) | Kubernetes / Cluster as rendered. |
| [`2026-08-24-grafana-jenkins-delivery.png`](2026-08-24-grafana-jenkins-delivery.png) | Jenkins & Delivery as rendered, including the deployed release. |

**The capture earned its existence on its first run.** The site was serving the internet normally and
every scrape target was up, but the in-cluster canary could not resolve `voteball.latnook.com`, so
`voteball:journey_requests:rate5m` was 0 and availability fell back to `or vector(1)` — 100% measured
over nothing. CoreDNS was serving a cached NEGATIVE answer from before external-dns created the A
record; because that name already exists in Route53 (a `google-site-verification` TXT record), the
answer was NOERROR-with-no-A rather than NXDOMAIN, cached against the zone's SOA minimum of 86400s.
The tell is that **TXT resolved and A did not**. `deploy.sh` step 11c now runs
`scripts/verify-public-dns.sh` at the end of every deploy.

`VoteballJourneyTrafficStopped` caught it unaided — `pending` six minutes in, and it would have fired
at ten. That alert doing its job on a defect nobody planted is worth more than the drill that proved
it could.

The screenshots are taken by [`../../../scripts/capture-grafana-screenshots.js`](../../../scripts/capture-grafana-screenshots.js),
which needs node and a global playwright — the only capture here that steps outside bash/curl/kubectl,
which is why it is a separate script rather than part of the shell one.

## 2026-08-20 — Task 4 re-captured on the rebuilt cluster

The current Task 4 static capture, taken on the cluster rebuilt this morning (Jenkins release
installed 09:43 IDT), after the pipeline had already run today's work end to end: `application-ci`
#1/#3/#5/#7 all SUCCESS, `application-cd` #1–#4 all SUCCESS, and #2/#4/#6/#8 `NOT_BUILT` — the Guard
stage refusing CD's own tag-bump commits, which is the loop this repository has no `[skip ci]` support
to break any other way. It supersedes the `2026-08-17-task4-*` files as the current-state capture;
those stay as the record of what they recorded. **The rollback demo was re-run too** (14:36 IDT, at
the repo owner's request), which turned out to matter: the CD pipeline gained a Monitoring Gate since
08-17, and the rollback path through that gate had never actually executed.

**What re-capturing found this time: two documentation drifts, both mechanically checkable, both
introduced by the Task 5 observability pass** (fixed in the same commit as this capture):
`README.submission.md`'s Task 4 stage lists and the Pipeline Flow diagram in `docs/eks/architecture.md`
both still described the pipelines *before* `Observability Validation` (CI) and `Monitoring Gate` (CD)
were inserted into them; and the test count was asserted twice, differently, in two files — 250 in
`README.submission.md` and 280 in `docs/cicd.md` — against an actual 289 (241 backend + 48 worker) in
today's run. The README's own phrasing ("in order, from `Jenkinsfile-ci`") is what makes that a defect
rather than a rounding: it invites the reader to diff it against the file.

| File | What it is |
|---|---|
| `2026-08-23-kubectl.txt` | The required kubectl outputs, captured after the 2026-08-23 rebuild — the first cluster built from the post-review repo (split egress policies, digest-pinned images, `release`-branch GitOps) |
| `2026-08-23-demos.txt` | The integration demos, including three added for the review findings. **Demo 5b** is the one to read: the frontend is proven unable to reach RDS (T3-1) as a *controlled* experiment — `backend -> RDS:5432` connects on the same host, and `frontend -> backend:5000` connects, so the single failing leg is the policy and not a missing tool or a wrong hostname. **Demo 5c** shows zero `kube-api-access` volumes in frontend/backend (T3-3). **Demo 5d** shows every workload running `repo@sha256:...` rather than a tag |
| `2026-08-23-pod-restart-poll.txt` | 113 probes across a frontend pod deletion, 0 non-200 |
| `2026-08-23-task4-ci-run.txt` | `application-ci` #3, SUCCESS. Proves two review fixes at once: `[Pipeline] junit` → `Recording test results` (289 tests published as Jenkins test results, not just archived XML), and **all four** images scanned `(blocking)` including `backup`, which now passes with zero findings after the unused `gosu` binary was removed |
| `2026-08-23-task4-cd-run.txt` | `application-cd` #3, SUCCESS — the full path on the new branch model: Promote writes a commit on `release`, Verify reports `digest matches the one 365ff2d resolves to` for all three Deployments, smoke test green, monitoring gate p95 0.096s |
| `2026-08-23-task4-cd-digest-verify-regression.txt` | **A failure, kept deliberately.** `application-cd` #1 rolled back a perfectly healthy release: ArgoCD `Synced`/`Healthy`, pods Running, site serving 200 — but Verify still asserted the running image *ends in the requested tag*, and digest-pinned images carry no tag. The rollback build then failed identically and `ROLLBACK_DEPTH` correctly stopped it rather than looping. The safety machinery worked; the assertion it acted on was stale. Fixed by `scripts/ci/verify-deployed-image.sh`, which compares digests and is offline-tested |
| `2026-08-23-task4-ci-run-scripts-only.txt` | `application-ci` #5 — a commit touching only pipeline scripts. Shows the changeset gates doing their job: tests and lint run, no image is built, and CD is not triggered |
| `2026-08-23-digest-pinned-bootstrap.txt` | **A fix verified by a second rebuild, because the deploy that found it could not test it.** The first rebuild left master's `image.digests` empty while `release` carried real ones, so Helm (step 10) and ArgoCD (step 11) rendered different image references and every workload rolled **twice** — `deployment.kubernetes.io/revision = 2`. The fix could not be applied mid-run (editing a running bash script corrupts it), so it shipped verified only by reasoning and an offline test. This capture is its first live exercise: **revision = 1** on all three, and `git diff master release` returns **nothing at all** — the branches are byte-identical, so ArgoCD had nothing to change. Also exercises `promote-to-release.sh`'s `read-tree` *update* path, since the release branch survived the teardown |
| `2026-08-23-task4-cd-rollback-broken-deploy-run.txt` | **The deliberate rollback drill.** `/api/options` was broken to return 503 while `/` (the readiness-probe target) was left working — so the pods stayed Ready, ArgoCD's rollout SUCCEEDED, and the failure landed on the **Smoke Test**, the only check in the pipeline that asks the product whether it works. `smoke: attempt 1/15 on /api/options -> 503` … then `ROLLING BACK to 365ff2d`. A different path from the 2026-08-20 drill, which died at Rollout and never reached the smoke test |
| `2026-08-23-task4-cd-rollback-recovery-run.txt` | The rollback build itself, SUCCESS — `/api/options` back to 200 |
| `2026-08-23-task4-rollback-site-poll.txt` | 767 continuous samples of **both** `/` and `/api/options` across the whole drill. `/` never returned anything but 200; `/api/options` shows 177 × 503 and then recovery. Check it yourself: `awk '$2!="/=200"' <file>` prints nothing |
| `2026-08-23-task4-verify-jenkins.txt` | `verify-jenkins.sh` under `VERIFY_STRICT=1` on the rebuilt cluster — exit 0, zero skips |
| `2026-08-20-task4-jenkins-on-k8s.txt` | The brief's §2 mandatory components and §6 container security read off the **running** objects: namespace separation, pinned controller images, probes, resource requests/limits, securityContext, the EFS-backed `Retain` PV, `numExecutors: 0`, no AWS role on the controller, both agent pod templates, the one container allowing privilege escalation, `docker.sock` mounted nowhere, NetworkPolicies, the CD identity proven read-only, no `cluster-admin` in `ci`. This capture also catches an **agent pod mid-build** — `voteball-build-f8q8t 9/9 Running 11s` alongside the 129-minute-old `jenkins-0` — which is the §10 "agent Pod created for a build" proof in a single frame: the controller is long-lived, the agent is seconds old, and only `jenkins-0` remains in every other capture here |
| `2026-08-20-task4-plugins-resolved.txt` | The 10 top-level plugins in `plugins.txt` resolved to the **86** actually loaded, with versions, next to the controller image tag that pins them |
| `2026-08-20-task4-verify-jenkins.txt` | `verify-jenkins.sh` under `VERIFY_STRICT=1` — exit 0, zero skips, including the credentialed half (exactly two jobs, `numExecutors` 0) |
| `2026-08-20-task4-argocd-check.txt` | `render-argocd-app.sh --check`: the live `Application`/`AppProject` match the template, no hand-registered repo or cluster credentials |
| `2026-08-20-task4-ci-run.txt` | `application-ci` #7, a full green run on commit `9a58532`: Guard → Validation → **Observability Validation** → Script tests → Lint → Tests (241 + 48 passed) → Build (4 contexts) → Trivy (the three blocking images `backend`/`worker`/`nginx` all `Total: 0`; the third-party `backup` base reports 22 without blocking) → Push → Publish Metadata (backend digest `sha256:f327454…`) → Trigger CD. The agent pod is provisioned per build — `Agent voteball-build-npv3h is provisioned from template voteball-build` |
| `2026-08-20-task4-cd-run.txt` | `application-cd` #4, the deploy of that exact tag — no rebuild: Input Validation → Manifest Validation → Promote → Deploy → Rollout → Verify `Synced`/`Healthy` → Smoke Test → **Monitoring Gate** (`p95 0.093s`, within the 1s budget) |
| `2026-08-20-task4-cd-rollback-broken-deploy-run.txt` | `application-cd` #5 — the deliberately broken deploy (`dead10c`, a frontend that 500s on `/`; the other three images are byte-identical copies of `9a58532`). Sync times out at 600s, diagnostics are dumped **before** anything is undone (`Startup probe failed: HTTP probe failed with statuscode: 500`), then `previous-tag.sh` → `9a58532`, `rollback-target.sh` confirms it is still in ECR, and `ROLLING BACK to 9a58532` |
| `2026-08-20-task4-cd-rollback-recovery-run.txt` | `application-cd` #6 — the rollback build at `ROLLBACK_DEPTH=1`, verifying itself green through the same stages, **including the Monitoring Gate with its 330-second settle wait** — the branch that only executes when the build *is* a rollback, and the first time it has run for real |
| `2026-08-20-task4-rollback.txt` | The measured timeline: 11:50:57 sync timeout → 11:51:22 rollback decision → 11:57:20 recovered and smoke-tested (**6m08s** detection to recovery), then the gate passing at 12:03:52. Explains why this is slower than 08-17's 2m08s: the apply itself took **26 seconds**, but could not start for ~4m40s while ArgoCD retried the *failed* sync of the broken revision, and the Monitoring Gate then ran its rollback-only 330s settle |
| `2026-08-20-task4-rollback-site-poll.txt` | **2,561** probes at 2/s spanning 11:39:29Z→12:04:28Z — the entire demo. 2,560 × HTTP 200 and **one `000`** at 11:52:31Z: no response inside the client's 5s timeout, not an error served by the site. Prometheus recorded `voteball:journey_errors:rate5m` at **0** throughout and availability `1` — on a **non-zero denominator** (`voteball:journey_requests:rate5m` held 0.056→0.21/s, the canary doing its job), so that `1` is a measured value and not the `or vector(1)` no-data fallback. Recorded rather than rounded away — `awk '$2!=200' <file>` prints that one line |
| `2026-08-20-task4-ci-guard-skip-run.txt` | `application-ci` #8 — the Guard stage stopping CD's own `ci: image tag 9a58532 [skip ci]` commit, `NOT_BUILT`, nothing built and nothing deployed. This is the build loop being broken, captured live |

## 2026-08-17 — Task 4 re-captured, and three faults it exposed

The current Task 4 set, captured on the live cluster after the 2026-08-17 rebuild. It supersedes the
`2026-08-04-task4-*` files as the current-state capture; those stay as the record of what they
recorded.

**Re-capturing was not a formality — it found three real faults, two of them in things that were
claimed to work.** That is the argument for capturing evidence from the running system rather than
describing it:

- **CI was broken and nobody knew.** `application-ci` **#1** failed on `CVE-2026-53615`: nine HIGH
  findings in Debian 13.6's `util-linux` family in the `backend` image. **Nothing in `services/` had
  changed since the last green build six days earlier.** The Trivy gate is
  `--severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed`, and `--ignore-unfixed` makes it sharp in
  one direction only: a base-package CVE is invisible while unfixed and **instantly blocking** the
  moment Debian ships the patch. Fixed at source (`apt-get upgrade` in both Debian images), not with a
  `.trivyignore` — the findings had a named fixed version, which is the one case the gate exists to
  catch. See `docs/security.md`, "Base-image patching".
- **The rollback could not have worked.** `previous-tag.sh` returned `61256d4`; ECR held only
  `480ee8b`. Git history survives a teardown, ECR does not, so between a rebuild and the first
  successful CD promote the "previous" tag belongs to the *old* cluster's registry. Worse than a failed
  rollback: the rollback build died in Input Validation — *before* Promote, so the depth bound never
  ran — and blamed a bad parameter. Now guarded by `scripts/ci/rollback-target.sh`.
- **Three documented claims were wrong**, all mechanically checkable: the test count (153 vs an actual
  250), a CI stage missing from `README.submission.md`'s stage list (`Script tests`, added
  2026-08-11), and `docs/deploy.md` documenting 14 of `deploy.sh`'s 15 steps — the missing one being
  **7b**, which mints the token CD authenticates with.

**The rollback demo ran with zero visitor impact**, unlike 2026-08-04's: 1,539 probes of the live site
across the whole cycle, all 200. Both demos are kept because they exercise different layers — see the
note in `2026-08-17-task4-rollback.txt`.

| File | What it is |
|---|---|
| `2026-08-17-task4-jenkins-on-k8s.txt` | The brief's §2 mandatory components and §6 container security, read off the **running** objects: namespace separation, pinned controller images (and a `:latest` grep returning nothing), probes, resource requests/limits, securityContext, the EFS-backed `Retain` PV, `numExecutors: 0`, no AWS role on the controller, both agent pod templates parsed as YAML, the **one** container allowing privilege escalation, `docker.sock` mounted nowhere, NetworkPolicies, the CD identity proven read-only, and no `cluster-admin` in `ci` |
| `2026-08-17-task4-plugins-resolved.txt` | The 9 top-level plugins in `plugins.txt` resolved to the **79** actually loaded, with versions, next to the controller image tag that pins them. New in this set: the Dockerfile records this in the image *build log*, which is ephemeral and outside the repo, so no reviewable file said which versions a tag contains |
| `2026-08-17-task4-verify-jenkins.txt` | `verify-jenkins.sh` under `VERIFY_STRICT=1` — exit 0, **zero skips** (a permissive skip reads identically to a passing check in a log) |
| `2026-08-17-task4-argocd-check.txt` | `render-argocd-app.sh --check`: the live `Application`/`AppProject` match the template, no hand-registered repo or cluster credentials |
| `2026-08-17-task4-ci-run.txt` | `application-ci` #3, a full green run: Guard → Validation → **Script tests** → Lint → Tests → Build (4 contexts) → Trivy (all three blocking images `Total: 0`) → Push → Publish Metadata → Trigger CD |
| `2026-08-17-task4-ci-scan-blocks-deploy-run.txt` | `application-ci` #1 — **a failed scan blocking the deploy.** `Push to ECR`, `Publish Metadata` and `Trigger CD` all `skipped due to earlier failure(s)`; nothing reached ECR and `application-cd` never ran |
| `2026-08-17-task4-ci-path-filter-skip-run.txt` | `application-ci` #2 — the `services/**` path filter correctly skipping build/scan/push for a docs-only commit, and reporting SUCCESS without shipping anything |
| `2026-08-17-task4-cd-run.txt` | `application-cd` #1: Input Validation → Manifest Validation → Promote → Deploy → Rollout → Verify at `sync=Synced health=Healthy` → smoke test green |
| `2026-08-17-task4-cd-rollback-broken-deploy-run.txt` | `application-cd` #2 — the deliberately broken deploy. Sync times out at 600s, diagnostics are dumped **before** anything is undone, and `ROLLING BACK to f5f5c75` |
| `2026-08-17-task4-cd-rollback-recovery-run.txt` | `application-cd` #3 — the rollback build, `ROLLBACK_DEPTH=1`, verifying itself green through the same stages the failed deploy used |
| `2026-08-17-task4-rollback.txt` | The measured timeline: 10:22:24 timeout → 10:22:41 rollback decision → 10:24:32 recovered and smoke-tested. **2m08s** from detection to recovery |
| `2026-08-17-task4-rollback-site-poll.txt` | **1,539** probes at 2/s spanning 10:11:09→10:26:08 — the entire demo — **all 200**. Check it, don't believe it: `awk '$2!=200' <file>` prints nothing |
| `2026-08-17-task4-rollback-target-guard.txt` | The guard's two verdicts against the **live** registry: exit 3 / `NO_ROLLBACK_TARGET 61256d4` for the tag the rebuild deleted, exit 0 for one that is present, plus the 9-assertion offline test |

**Why the poll is throttled to two requests a second** — same reason as the 2026-08-03 set below:
`terraform/waf.tf`'s `RateLimitSiteWide` blocks an IP at 2,000 requests per 5 minutes across *every*
path, and an unthrottled loop trips it and then reads exactly like an outage. The `sleep 0.5` is
load-bearing.

### …and then a full destroy → rebuild cycle, same day

Run after everything above, to check the whole system rather than the pipeline alone. **Teardown: exit
0, 144 resources** (132 on 2026-08-04 — the difference is the EFS filesystem, mount targets, CSI
add-on and StorageClass added since). **Rebuild: exit 0, 135 resources added, ~20 minutes.**
**Votes survived: 22 previous / 29 upcoming**, against 18 / 23 on 2026-08-04 — *higher*, which is
preserved data plus thirteen days of real voting. Lower would have meant the restore lost something.

Three things this cycle produced that the pre-teardown set could not:

- **The rollback-target gap, occurring on its own.**
  `2026-08-17-task4-rollback-target-post-rebuild.txt` catches it minutes after the rebuild, before the
  first CD promote closed the window: production on `281daad`, `previous-tag.sh` naming `f5f5c75`, and
  ECR holding only `281daad`. Earlier the same day the verdict had to be *demonstrated* by handing the
  guard an old tag, because the window had already shut. This is the unstaged version.
- **The dirty-tree guard stopping a real deploy.** The first `deploy.sh` invocation (kept in
  `2026-08-17-deploy-steps.txt`, both invocations in order as with the 2026-08-03 set) died at step 5
  because the destroy log above was still an untracked file. Images are tagged from git, so building
  would have published `165cea4` containing a file that commit does not have — and nothing downstream
  would have noticed. It failed *before* the billed apply at step 6, which is the whole reason the
  guard sits there.
- **The final-snapshot naming trap, live.** `voteball-eks-db-final-20260817084122` was created at
  **12:14:14Z** — the identifier embeds `time_static.deploy` (08:41 UTC), so the name reads 3.5 hours
  stale on a snapshot taken minutes earlier. Verify by `SnapshotCreateTime`, never by name.

**Jenkins build history did not survive, and that is correct.** The PVC came back as a *new* volume
(`pvc-dd841523…` vs `pvc-a3c6405a…`) so numbering restarted at `#1`: the PVC carries no
`helm.sh/resource-policy: keep`, so uninstalling deletes it and a reinstall provisions a fresh EFS
access point rather than rebinding the released one. The EFS *data* is retained; rebinding it would
need a manual step. What records what was deployed was never the build log — it is the
`ci: image tag <sha> [skip ci]` commits on `master`.

| File | What it is |
|---|---|
| `2026-08-17-destroy-steps.txt` | Six ordered teardown steps, `ALL` three Helm releases uninstalled while the cluster was still healthy, `Destroy complete! Resources: 144 destroyed.` No hang, no state lock, no retry |
| `2026-08-17-deploy-steps.txt` | **Both** invocations: the dirty-tree guard refusing at step 5, then a clean run — all fifteen steps, `Apply complete! Resources: 135 added`, `Deploy complete.` |
| `2026-08-17-task4-rollback-target-post-rebuild.txt` | The git-vs-ECR disagreement occurring unprompted, and the guard returning `NO_ROLLBACK_TARGET f5f5c75` at exit 3 |
| `2026-08-17-task4-post-rebuild-jenkins-on-k8s.txt` | The §2/§6 components again, on the **rebuilt** cluster — every node IP, pod name and PV is new |
| `2026-08-17-task4-post-rebuild-plugins-resolved.txt` | The same 9 → 79 plugin resolution from the rebuilt controller |
| `2026-08-17-task4-post-rebuild-verify-jenkins.txt` | `VERIFY_STRICT=1`, exit 0, zero skips — on a controller built minutes earlier and **never clicked** |
| `2026-08-17-task4-post-rebuild-argocd-check.txt` | ArgoCD again matching the repo, with no hand-registered credentials |
| `2026-08-17-task4-post-rebuild-ci-run.txt` | `application-ci` #1 on the fresh controller: `First time build. Skipping changelog.` and it **builds anyway** (G3b), all three blocking images `Total: 0`, then triggers CD |
| `2026-08-17-task4-post-rebuild-cd-run.txt` | `application-cd` #1: promote → sync → `sync=Synced health=Healthy` → `smoke: all checks passed` |

`application-ci` #2 on that controller is `NOT_BUILT` — the Guard aborting CD's own tag-bump commit,
the G2 loop protection firing on a cluster that is twenty minutes old.

## 2026-08-04 — a clean first-run rebuild, and the CI/CD split going live

**Superseded as the current-state capture by the 2026-08-17 set above** (its `task4-*` files predate
the `Script tests` stage, the base-image patching and the rollback-target guard). Kept as the record
of the first-run rebuild and of the automatic rollback firing on a backend that passed its probes
while serving 500s — a failure mode the 08-17 demo deliberately does not reproduce.

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

## 2026-08-25 — a second destroy → rebuild cycle, to test the Grafana data sources

| File | What it is |
|---|---|
| `2026-08-25-destroy-deploy-cycle.txt` | A full teardown and rebuild run to answer one question: does the Grafana data-source work survive a cold start? It found two defects that could not exist on the healthy cluster — a `GITHUB_TOKEN` in `deploy.env` that broke every `git push` in the deploy (git and `gh` consume that name automatically), leaving a "successful" deploy with **no ArgoCD Applications at all**; and a step that checked for a Secret once, ~90 seconds before it existed. It also records an operator error worth keeping: step 9's guard said *"Refusing to bootstrap ArgoCD — it would sync a stale image tag"*, was overridden by hand, and every consequence it predicted then happened. |

Unlike the 2026-07-27 set above, this is a narrative record rather than raw command captures — the
value is in the sequence of failures and what each one proved, not in the untrimmed output.

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
