# scripts — CLAUDE.md

*Moved verbatim from the root `CLAUDE.md` on 2026-10-02 so it loads only when working here. Where a paragraph says "above" or "below" about something not in this file, it is in one of: `terraform/CLAUDE.md`, `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`, `charts/observability/CLAUDE.md`, `charts/voteball/CLAUDE.md`, or the `voteball-cicd` skill.*

## Deploy

**`deploy.sh`'s preflight REPAIRS the EKS API allow-list rather than warning about it**
(`./scripts/refresh-api-cidr.sh --ensure`, before step 1). `cluster_endpoint_public_access_cidrs`
names a home ISP address, so it goes stale on its own schedule, and when it does AWS **drops** this
machine's packets rather than refusing them — so every `helm_release` and `kubernetes_*` resource in
step 6 fails with `Kubernetes cluster unreachable ... i/o timeout` and the run reads as a dead
cluster, ~13 billed minutes in. A warning was already printed there and it did not help: it scrolled
past hundreds of lines above the errors, which named the cluster and not the list (2026-08-26).
**`--ensure`, never the plain form, is what an unattended run may call**: it acts only when the list
does not already *cover* this machine (containment, not string equality — `["0.0.0.0/0"]` covers it),
and when it does act it keeps every entry broader than a `/32` and replaces only stale single-host
pins. The plain form replaces the whole list with one `/32`, which is correct for a human and would
silently lock out a CI runner or a second operator here. `VOTEBALL_NO_CIDR_FIX=1` restores
warn-only.

**`./scripts/deploy.sh` / `./scripts/destroy.sh`** run the full ordered sequence (both stop for
confirmation before Terraform touches billed resources; `VOTEBALL_AUTO_APPROVE=1` skips the prompt
for unattended runs only). **`VOTEBALL_AUTO_APPROVE=1` alone does NOT make `deploy.sh`
unattended** — the admin password (and, since the in-cluster Jenkins move, a Jenkins username +
password) is prompted on `/dev/tty`, so a detached run also needs `ADMIN_PASSWORD`,
`JENKINS_ADMIN_USER` and `JENKINS_ADMIN_PASSWORD` in the environment (the db password is read from
`voteball.tfvars` and only needs to be passed as `DB_PASS` if it isn't there). All are collected in a
preflight check at the top of the script — *before* the billed `terraform apply` — because the
failure otherwise lands *after* a ~15-minute billed run (hit for real on the 2026-07-21 rebuild).
**Those three can live in a gitignored `deploy.env` at the repo root**, which `deploy.sh` sources
itself (`set -a`, then the pre-existing environment is re-asserted so an explicit
`ADMIN_PASSWORD=… ./scripts/deploy.sh` still wins). Until 2026-08-05 that file was *only* gitignored
— `.gitignore` had described it as "read by `scripts/deploy.sh`" since it was added, but nothing ever
read it, so every deploy prompted and the failure was invisible: a gitignored file cannot be checked
by any test, and the symptom is identical to not having one. `scripts/tests/test-deploy-env.sh` now
covers it, and deliberately **extracts the loader block out of the live `deploy.sh`** rather than
restating it — a restated copy would have passed throughout the whole period the real script ignored
the file. Note
`deploy.sh` is only re-runnable at a cost, and **the two seed scripts behave oppositely — do not
assume they match.** `seed-eks-secret.sh` rewrites the app secret **every run**: whatever
`ADMIN_PASSWORD` you supply becomes the new password, `ADMIN_USERNAME` silently reverts to `admin`
unless you pass it, and a fresh `ADMIN_SESSION_SECRET` invalidates every live admin session.
`seed-jenkins-secret.sh` is the reverse — it **exits early and changes nothing** once the secret
holds a deploy key, so re-running deploy does *not* update the Jenkins username or password. Those
only change under `FORCE_ROTATE=1`, which also mints a new deploy key and webhook secret and so
requires re-registering both on GitHub. Count `grep -nE '^\s*step "'
scripts/deploy.sh` for the current step numbers rather than reciting them here — they shift whenever
a step is inserted or moved, most recently 2026-08-04 when GitHub deploy-key registration moved from
the last step to **3c**, joining the two secret-seeding steps that moved *ahead* of the billed apply
on 2026-07-31 (now 3, 3b and 3c). **That order is load-bearing, not cosmetic**, for two separate
reasons. The full apply creates `helm_release.jenkins` and its ExternalSecret together, and ESO
copies the vault into the cluster once at creation and then only hourly — so seeding afterwards
boots Jenkins with no admin account and 401s every login for an hour, while the deploy reports
success throughout. And step 9 pushes `values.yaml` to `master`, which the previous cluster's
surviving webhook fires on — so a deploy key registered any later than 3c arrives after the build
that needed it has already failed on `Permission denied (publickey)` (observed 2026-08-03: the gap
was 21 seconds). The reachability *probe* deliberately stays at 11b, since it needs a live Jenkins;
`register-github-ci.sh` splits the two via `SKIP_PROBE=1` / `PROBE_ONLY=1`.

**`./scripts/sync-values-from-tf.sh` manages ONE field in `values.yaml` — `image.tag` — since 2026-09-08.** The other nine environment fields are injected by the ArgoCD Application's `helm.parameters` (`scripts/render-argocd-app.sh`), and the committed file carries `REPLACED-BY-ARGOCD` placeholders for them. **Never hand-edit `image.tag`.** `--check` fails on drift *and* verifies `image.tag` names an image that exists in ECR. Its only test is `scripts/tests/test-sync-values.sh` (runs offline via `SYNC_STUB_*` env vars); **extend it whenever you add a managed field.** *(This paragraph replaced one that still said "ten fields, real values" on 2026-10-02 — check the `managed` dict in the script, not this sentence.)*

**Read the `release` branch by CONTENT, never by ancestry.** `promote-to-release.sh` builds each
release commit with `git read-tree`, not a merge, so a `master` commit is *never* an ancestor of the
release commit that carries it — `git merge-base --is-ancestor <sha> origin/release` returns false
even when the tip literally reads `release: <sha>`. Use `git show origin/release:<path>` (which is
what `current-release-tag.sh` and `previous-tag.sh` already do, correctly). Anything that checks
promotion by ancestry reports "not promoted" forever.

## Secrets

**Secrets:** `./scripts/seed-eks-secret.sh` takes `ADMIN_USERNAME`/`ADMIN_PASSWORD` from the
environment or a silent prompt and writes them to Secrets Manager; nothing secret enters git or
tfstate. `DB_PASS` **must** match `db_password` in `terraform/voteball.tfvars` — so it now defaults
to reading it straight from there (`tf_db_password` in `scripts/lib/config.sh`), which makes the
match automatic; pass `DB_PASS` in the environment only to override.

**On EKS, secrets live in AWS Secrets Manager** (`voteball/app-secret`) and are synced into the
`app-secret` Kubernetes Secret by External Secrets Operator via IRSA. Terraform creates only the empty
container (`ignore_changes = [secret_string]`), so **no secret value ever enters git or tfstate**.
See `docs/security.md`.

Seed the values with `./scripts/seed-eks-secret.sh`, which takes `DB_PASS`, `ADMIN_USERNAME` and
`ADMIN_PASSWORD` from the environment or a silent prompt, hashes the password with `werkzeug` and
generates `ADMIN_SESSION_SECRET` itself. Nothing is echoed or written to disk. **`DB_PASS` must match
`db_password` in `terraform/voteball.tfvars`** — Terraform sets the RDS master password from
that variable (including on a snapshot restore, which is what keeps the two in sync).

*(The old ansible-vault mechanism was removed with the k3s stack on 2026-07-20.)*

See `docs/deploy.md` for the full deploy/destroy runbook.

## Teardown

**Teardown order matters** and `./scripts/destroy.sh` encodes it: delete **all three** ArgoCD
Applications (`voteball`, `observability`, and — since the EFK logging pass — `logging`; else
`selfHeal` recreates what you remove), then **all three Ingresses** (so the ALB de-provisions and
external-dns removes its records — a leftover ALB's ENIs block VPC deletion), wait for the ALB to
disappear, **uninstall this stack's own SIX Helm releases while the cluster is still healthy**
(`voteball`, `jenkins`, `jenkins-support`, `kube-prometheus-stack`, `logging`, `elastic-operator` — see
below), *then* `terraform destroy`. `logging` and `elastic-operator` come out in that specific order —
custom resources and chart first, operator last — for the same reason given under "ECK operator" above.

**"All three" is load-bearing.** Since 2026-07-31 `devops-app/voteball` and `ci/jenkins-webhook` share
ALB group `voteball`, and an ALB is de-provisioned only when its group has **no** members left —
deleting some and not all of them leaves it running. The same change renamed the ALB: a grouped one is
`k8s-<group>-<hash>`, not `k8s-<namespace>-<ingress>-<hash>`, so any check filtering on the old shape
reports "ALB gone" instantly while it is still there. `logging/kibana` joined as the group's **third**
member during the EFK logging pass, and step 2 deletes it explicitly, alongside the other two, rather
than leaving it to step 4's `helm uninstall logging` — that runs **after** step 3 already starts
waiting for the ALB, which would reproduce the exact 10-20 minute hang this step exists to prevent, for
the group's third member. (This was a real gap for one review cycle: step 2 deleted only the first two
Ingresses while Kibana's joined the group, so a fresh teardown could wait out step 3's full timeout on
an ALB that could not de-provision yet. Fixed the same day it was found;
`scripts/tests/test-logging-teardown.sh` asserts both that the delete exists and that it precedes the
ALB wait, proven by reverting each independently and watching the check name the right failure.)
`./scripts/cleanup-stale-dns.sh` cleans the matching **three** hosts (`<app_domain>`,
`jenkins.<app_domain>`, `kibana.<app_domain>`).

**`terraform destroy` uninstalls `helm_release`s itself when it reaches them, and doing that while the
cluster is simultaneously being deleted underneath it is what hung with `context deadline exceeded`**
(observed 2026-08-04, on `helm_release.jenkins`: Helm cannot cleanly uninstall from a cluster that's
disappearing). `destroy.sh` avoids this for its own six releases by uninstalling them explicitly one
step earlier, while every node and controller is still up — the situation Helm actually expects, not a
workaround for it. `external-secrets` is deliberately left **out** of that pre-uninstall: its
controller has to stay alive until Terraform deletes the `ci`/`devops-app` namespaces, because the
ExternalSecret/SecretStore custom resources inside them carry finalizers only that controller can
clear. Pulling it out early just relocates the same hang one step earlier — which is exactly what
happened by hand on 2026-08-04: `helm_release.external_secrets` was dropped from state pre-emptively,
and `kubernetes_namespace.ci` then sat `Terminating` forever with no controller left to clear its
children's finalizers.

**That ordering is now ENFORCED, and until 2026-09-07 it was only described.** Leaving ESO out of the
pre-uninstall list does not by itself tell Terraform anything, so Terraform scheduled
`helm_release.external_secrets` and the namespaces in the *same parallel batch* — on the 2026-09-07
teardown `helm_release.external_secrets: Destroying...` printed one line **before** the namespaces
started, and the run died on `context deadline exceeded`. The mechanism is
`depends_on = [module.compute, helm_release.external_secrets]` on `kubernetes_namespace_v1.devops_app`
and `kubernetes_namespace_v1.ci` (plain `kubernetes_namespace` until the 2026-09-15 provider v3 move), which is a **destroy**-order constraint: Terraform destroys dependents
before their dependencies, so naming ESO there is what makes the namespaces go first and the
controller outlive them. `kubernetes_namespace_v1.logging` deliberately does **not** carry it —
`charts/logging` ships no ExternalSecret, and its hang is a different problem with a different fix
(see the ECK note below). Verify the edges with
`terraform graph | grep 'kubernetes_namespace.* -> "helm_release.external_secrets"'`; a documented
invariant with no mechanism is not an invariant.

**That ordering fix works and is still not sufficient alone — `observability` is the hole.** Proven
on the 2026-09-08 10:19 teardown: `devops_app` and `ci` completed cleanly in 13s and 12s *before*
ESO was touched (on the previous run ESO went first), and `helm_release.external_secrets` **still**
ran exactly `05m00s` — Helm's default timeout — and failed. `depends_on` is a per-namespace fix and
`observability` has no Terraform resource to hang it on: that namespace is created by the
`kube-prometheus-stack` release, and `charts/observability` puts an ExternalSecret in it. The
external-secrets chart ships its **CRDs as ordinary templates**, so `helm uninstall` tries to delete
the `externalsecrets` CRD, which blocks on every surviving custom resource's finalizer with no
controller left to clear them. `destroy.sh` step 4 now sweeps `externalsecrets`/`secretstores`
(`--all-namespaces`) and `clustersecretstores` (cluster-scoped, so **not** `--all-namespaces`) while
the controller is still alive. **When a namespace is added, prefer the sweep to another
`depends_on`** — the ordering fix must be repeated for every future namespace, the sweep need not.

**If `terraform destroy` still hangs this way — on a `helm_release` it manages that isn't one of the
six pre-uninstalled above, or on a `kubernetes_*` resource the way `kubernetes_namespace.ci` did —
`destroy.sh` now recovers automatically, once.** On a failed destroy it drops every remaining
`helm_release.*` and `kubernetes_*` resource from state — **never an `aws_*` resource**, since that
would orphan billed infrastructure with nothing left in Terraform's records to find it by — and
retries `terraform destroy` exactly one more time. Both kinds of resource die with the cluster
regardless of whether Terraform got to clean them up first, so forgetting Terraform ever created them
costs nothing. If the retry also fails, the script exits non-zero having printed what it removed and
the real remaining error; it does not loop further.

**A `terraform destroy` interrupted mid-run (Ctrl-C, a command timeout) leaves an S3 state lock.**
`destroy.sh` detects `Error acquiring the state lock` and prints the exact recovery — the lock file's
path (`s3://<cluster_name>-tfstate-<account_id>/voteball/main.tfstate.tflock`), the lock id parsed out
of Terraform's own error, and the `terraform force-unlock <id>` command — rather than clearing it
automatically: a held lock can legitimately mean another operator is mid-apply, and force-unlocking
that case can corrupt state, so that judgment call is left to whoever runs the script.

RDS takes a **final snapshot on destroy** (since 2026-07-20), so destroy→rebuild preserves votes;
`find-latest-snapshot.sh` picks the newest one up automatically before the next apply. Two traps
around this, both hit for real on the 2026-07-27 rebuild (see `docs/production-readiness.md` §3):

- **Verify the final snapshot by `SnapshotCreateTime`, never by its name.** The identifier embeds
  `time_static.deploy`, so a snapshot created today is named after the day the stack was *deployed*.
  A fresh snapshot called `voteball-eks-db-final-20260722065933` on 2026-07-27 looks five days stale;
  concluding "the final snapshot failed" from the name is the natural — and wrong — reading.
- **The nightly `pg_dump` in S3 is not teardown insurance.** `terraform/modules/storage/main.tf` sets
  `force_destroy = true`, so `terraform destroy` deletes the rollups bucket and every backup in it,
  during the same run it would supposedly be insuring. The layers that do survive are the final
  snapshot and **retained automated backups** (`delete_automated_backups = false`). Don't count the
  dumps when deciding whether a teardown is safe.

Seven teardown behaviours `destroy.sh` handles that a manual `terraform destroy` does not:
- **`./scripts/cleanup-stale-dns.sh`** removes this cluster's Route53 records if external-dns didn't get
  to it first (it only reconciles on a timer and can be destroyed before noticing the deleted Ingress).
  Gated on the ownership TXT (`external-dns/owner=voteball`), so apex/MX/DKIM records are never eligible.
- **An orphaned-ENI reaper** runs in the background during destroy. The VPC CNI leaves detached
  `aws-K8S-*` interfaces when nodes terminate, and they make Terraform retry `DeleteSubnet` against a
  `DependencyViolation` for 10–20 minutes. See `docs/deploy.md` troubleshooting for the manual command.
- **A load-balancer leftover sweep** (`scripts/cleanup-orphaned-lb-resources.sh`), once before the
  destroy and again inside the ENI reaper loop. On 2026-09-16 the ALB vanished from the ELB API while
  AWS kept its `amazon-elb` interfaces attached for ~6 hours, so the controller never deleted its two
  security groups or its target group, and `aws_vpc` sat on "Still destroying..." until they were
  removed by hand. Eligibility is the controller's own `elbv2.k8s.aws/cluster=<cluster>` tag (its IAM
  policy cannot create one without it), and the sweep does nothing while any load balancer or ELB
  interface remains in the VPC. The reaper-loop call is the half that matters: AWS released the
  interfaces mid-teardown, and only a sweep running at that moment can use it.
- **Pre-uninstalling all six of this stack's own Helm releases while the cluster is still healthy**
  (`voteball`, `jenkins`, `jenkins-support`, `kube-prometheus-stack`, `logging`, `elastic-operator`
  — count them in `scripts/destroy.sh` step 4 rather than trusting this list), and **one bounded automatic retry** (state-rm on `helm_release.*`/`kubernetes_*` only,
  never `aws_*`) if `terraform destroy` still hangs — see above for both.
- **State-lock detection** — prints the exact `force-unlock` recovery instead of failing opaquely, and
  never force-unlocks on its own (see above).
- **Pruning old DB snapshots** (`scripts/prune-db-snapshots.sh --apply`, second-to-last step, non-fatal). Every
  teardown takes a final snapshot and nothing ever deleted one, so by 2026-09-09 there were **52**
  going back to 2026-07-19 and RDS backup storage had become the **largest RDS line item on the
  bill** — `ChargedBackupUsage` went $0.19 (Jul) → $4.21 (Aug) → $2.00 in the first nine days of
  September, against $1.06 of instance time in the same window. AWS gives free backup storage up to
  100% of allocated storage (20 GB here), which is why July was nearly free: the total crossed the
  allowance in August. Retaining **7** puts it back under. **Two rules the script must keep**: order
  by `SnapshotCreateTime` and never by identifier (the name embeds `time_static.deploy` — see the
  trap below), and use the **same predicate as `find-latest-snapshot.sh`**, which restores the newest
  match on the next deploy. A narrower predicate here would delete the snapshot the next apply is
  about to restore from. On top of `--retain` there is a hard floor: the newest is never deleted,
  whatever the number says. Dry-run by default; `destroy.sh` passes `--apply`.
- **Pruning orphaned EBS volumes** (`scripts/prune-orphaned-volumes.sh --apply`, last step,
  non-fatal). An orphaned volume blocks nothing, so `terraform destroy` reports success while leaking
  it. Step 5 deletes the PVCs so a clean teardown leaks none, but on 2026-10-05 the account still
  held **twelve** unattached volumes, 220 GB, from teardowns of 2026-08-23 to 2026-09-08 that
  predated that step, all billed while the stack was down. **Three rules the script must keep**: it
  **refuses to run while the EKS cluster exists** (a detached volume on a live cluster may be a pod
  mid-reschedule, and "cannot tell" counts as "exists"), which is why it runs after the destroy and
  must not be moved earlier; it matches on **two** markers, the `<cluster>-dynamic-pvc-*` Name tag
  **and** the `kubernetes.io/created-for/pvc/name` tag key, plus `available`; and it deletes only
  volumes created more than **7 days** ago (`ORPHAN_VOLUME_MIN_AGE_DAYS`). The age is measured from
  creation because EBS records no detach time. **It is not a timer**: nothing runs while the stack is
  down, so "after a week" means "at the first teardown after the volume is a week old".
  `scripts/tests/test-prune-orphaned-volumes.sh`'s fake `aws` applies the filters it is passed, so
  dropping any one of them deletes a fixture volume it must not.

## Checks that lie: swallowed exit statuses and silent name contracts

**A failing command whose exit status is swallowed by the thing that printed it — four mechanisms,
one bug.** This is the most-repeated defect shape in this repository, and
it is worth grepping for before writing anything that shells out:

- **Pipe position.** `terraform apply | tail` reports the exit status of `tail`, so a FAILED apply
  reads as 0. **The reverse bites under `pipefail`: `producer | grep -q` turns a MATCH into a
  miss** once the producer writes more than one pipe chunk — grep exits at the match, the
  producer's next write dies of SIGPIPE (141). `changed-paths.sh` answered "nothing changed" for
  every large commit this way, and `test-aws-pager-guard.sh` flaked only in CI (2026-09-17).
  Capture into a variable, or drop `-q` and redirect to `/dev/null`.
- **A status interpolated into a message that asserts success.** `scripts/drills/`'s first version
  printed `application-ci triggered (HTTP $code)` — and on 2026-08-24 that line read
  `application-ci triggered (HTTP 403)`, because a Jenkins CSRF crumb is bound to the session that
  issued it and the cookie had been discarded. Nothing was triggered. Drill 3 then killed an agent
  belonging to a build somebody else's push had started, and drill 5 would have watched an empty
  queue for 22 minutes and reported that `JenkinsQueueStuck` failed to fire — a false negative on an
  alert this repo has already wrongly written off once.
- **Measuring the wrong endpoint and reporting the number anyway.** The same day, drill 1 polled
  `https://<app_domain>/health` and logged a column of `404`s as though they were health checks.
  nginx proxies only `/api/*`, so that path never reaches the backend — which is also why
  `scripts/ci/smoke-test.sh` deliberately does not test it.

The common thread is that **the transcript looks MORE complete than a silent failure would.** A bare
error is visibly an error; a success line with a `403` inside it reads as a logged detail, and
evidence built on it gets believed. `set -euo pipefail` is necessary and covers none of them:
not a pipeline's non-final stage, not a `$(...)` whose output is merely printed, not a request that
succeeded against the wrong URL, not a lookup that quietly found real data it should never have had
access to. **And each needs a different fix, so "check the exit status" is
not the lesson:**

| Sub-type | Fix | How it is found |
|---|---|---|
| A discarded exit status | capture it into a variable and branch on it | reading the code |
| A race against state that has not arrived | a completion condition, or a retry | running it twice |
| A pattern that can never match | feed the check input you KNOW should match, once | **only** by that |
| A check that passes only where it ran | make its precondition real — deny the tool, unset the variable | **only** running it elsewhere |

The third is the worst and arrived last (2026-08-24, drill 4: `grep '^gate:'` against Jenkins console
lines, every one of which carries a timestamp prefix — the anchor could never match, so the section
was empty and correct). No amount of reading `grep '^gate:'` reveals that, and a retry cannot help.
Worse, its empty result is not merely indistinguishable from "nothing to report" — it is
indistinguishable from a **correct negative**, which is a legitimate outcome nobody has any reason to
investigate. Exercising a check against known-present input at least once is the only defence, and it
is the same discipline as proving a test can fail before trusting it to pass.

**A FOURTH sub-type, and the one this repo is most exposed to: a check that passes only because of
where it happened to run.** 2026-09-08 — `scripts/tests/` is *offline by contract*, and
`test-render-argocd-app.sh` stubbed one of the ten Terraform outputs `render-argocd-app.sh` reads
(the helm.parameters pass took it from one to ten and the test was not extended). On a developer
machine the other nine resolved against real S3 state, so the suite reported **30/30 green**; in
Jenkins, which has no AWS, the first unstubbed one hard-failed the build. **The test was offline by
accident, not by contract, and nothing in it said so.** This is *not* the "run it twice" sub-type —
it reproduces perfectly, every time, on the machine you are on. It also cannot be found by reading
the test, because the missing stub is invisible: the code that needs it is in the *other* file.
**The fix is to make the precondition real rather than assumed** — the test now puts a `terraform`
shim that exits 1 on `PATH`, so both environments are identical and the next output added fails for
whoever adds it. Generalise it: **a test that depends on something being absent must make it absent
itself.** Two more defects were sitting behind that one in the same file, both invisible until it
was fixed — a `2>/dev/null` around a whole pipeline reporting a failed assertion as "PyYAML not
installed" (it *is* installed), and the assertion itself pinned to four rendered documents when the
template has produced six since `logging` became the third Application. A dead check and a lying
skip line, protecting each other.

**A grep used to decide "is this repo clean?" IS one of these checks, and alternation is where it
hides.** Second instance, 2026-08-28, found by a doc audit rather than by the person who ran the
grep: sweeping for the superseded "3 clubs per league" cap with
`grep "at most 3 clubs per league\|up to 3 clubs\|3 clubs per league"` returned nothing for
`README.md:53`, which read "up to 3 **specific** clubs per league". One intervening word defeated
**all three alternatives at once**, because all three assumed `3` and `clubs` were adjacent — so they
were never three chances, they were one, and the zero-match result was indistinguishable from a file
that was already correct. **Alternation gives the feeling of coverage while sharing a single point of
failure.** Two defences, both cheap: search the narrowest token that must appear whatever the
surrounding words (`grep -n '\b3\b' README.md` returns both lines), and run the pattern once against
a line you KNOW should match before trusting a clean sweep. The same audit discipline applies in
reverse — the fix pass deliberately left `README.submission.md`'s HTTP `301` alone: same digits,
unrelated claim, and exactly what a careless sweep "fixes".

**A NAME that is a silent contract with something off-screen — four instances in one day
(2026-08-24), all four producing a confident, empty, correct-looking result and no error anywhere.**
This is the sibling of the swallowed-status family above: there the status was discarded, here the
receiver simply never recognised the word. Nothing rejects an unknown key; it is ignored, a default
is used, and the output looks like a legitimate negative.

| The name | Who else reads it | What went wrong |
|---|---|---|
| `GITHUB_TOKEN` | **git's credential helper and the `gh` CLI**, automatically | Put in `deploy.env`, which `deploy.sh` sources with `set -a`, so every `git push` and `gh` call in the deploy authenticated as a read-only fine-grained PAT. Step 9 died on `Permission to Latnook/voteball.git denied`, its guard then correctly refused to bootstrap ArgoCD, and the rebuild finished with **no ArgoCD Applications and `charts/observability` never deployed** — while reporting success and serving 200. Now `GRAFANA_GITHUB_TOKEN`. **Never introduce a bare `GITHUB_TOKEN` into any script's environment here.** |
| `envFromSecret` vs `envFromSecrets` | the Grafana subchart | The singular renders a **mandatory** `secretRef` with no `optional` field; only the plural (a list) supports `optional: true`. The singular pointed at a Secret that only a default-off ExternalSecret creates, so the next `terraform apply` would have `CreateContainerConfigError`d Grafana and taken all six dashboards down. |
| `queryMode` / `metricQueryType` / `metricEditorMode` | Grafana's CloudWatch **frontend**, not its backend | Absent from all ten metric targets. `/api/ds/query` filled defaults and returned real data, so every server-side check passed; the browser took the other branch and sent an empty query. The dashboard rendered "No data" while every verification said green. |
| `options.ref` vs `options.gitRef` | `grafana-github-datasource` 2.9.0 | The Commits panel returned 0 rows with `status=ok`. Measured: `gitRef` → 188 commits/7d, `ref` → 0, `gitRef: ""` → 0 (no default-branch fallback). |

**The defence is the same in every case and it is not code review.** Make both sides actually talk,
once, and count what comes back. Three of these four passed valid-JSON checks, valid-uid checks,
`helm lint`, `terraform validate` and an HTTP 200. The fourth passed a per-panel query sweep *through
the wrong code path*. What found them: a rebuild (the first two), and a human noticing that one panel
worked while its neighbour did not (the last two).

**Corollary — a check that only ever exercises one consumer proves nothing about the other.** The
per-panel sweep in this repo queries `/api/ds/query`. It cannot see a frontend-only failure, and it
reported 60/60 healthy against a blank dashboard. If a stored document is read by two different
consumers, they are two different contracts.

## AWS CLI v2 pager

**AWS CLI v2 pages its output whenever stdout is a terminal, and that hangs deploys.** v1 had no
pager at all, so nothing noticed until the repo owner upgraded on 2026-08-21. Every script in
`scripts/` runs at a terminal, so any `aws` call whose output is *not* captured or redirected stops
dead waiting for `q` — and it looks exactly like a hung AWS API call, not like a pager.

**Which commands page is not about output size — it is about which class implements them, and the
split is counter-intuitive.** Ordinary service commands (`sts get-caller-identity`,
`secretsmanager put-secret-value`, every `ec2 describe-*`) render through `OutputStreamFactory` and
**are** paged — even a single short line from `--query … --output text` hangs. The `eks`
customizations `update-kubeconfig` and `get-token` are `BasicCommand` subclasses that write straight
to stdout via `uni_print`, so they are **never** paged, however long their output. That exemption is
what keeps `kubectl` working at all: it shells out to `aws eks get-token` on every single request.
Do not infer a command's behaviour from its output — check whether it is a `BasicCommand`
customization, or just test it on a pty (`script -qec 'timeout 4 aws … ; echo RC=$?' /dev/null`, and
note the redirect must NOT go to `/dev/null` or there is no terminal and nothing pages).

The real hang sites are therefore the `--output text`/`--output table` calls in the seed and evidence
scripts — `deploy.sh` step 3b (`seed-jenkins-secret.sh`) and step 7b (`seed-argocd-token.sh`), both
`put-secret-value … --output text`. (Two more lived in `capture-evidence.sh`, deleted 2026-09-09.)
Steps 3b and 7b are the
expensive ones: 7b lands **after** the billed ~13-minute apply, so hanging there costs a rebuild
rather than a retry. (`deploy.sh`'s own `aws eks update-kubeconfig` at step 7 was originally listed
here and is **not** a hang site, per the `BasicCommand` rule above.) The fix is `export AWS_PAGER=""`, set once in
`scripts/lib/config.sh` (which 17 scripts source) and repeated in the two that cannot source it,
`scripts/ci/images-exist.sh` and `services/backup/backup.sh`. It is **forced, not defaulted** — a
`${AWS_PAGER-}` would honour a user's global `AWS_PAGER=less` and faithfully reproduce the hang.
**CI never saw any of this and never will**: Jenkins captures stdout, so it is not a terminal there,
and the agents have run `amazon/aws-cli:2.x` all along — which is exactly why it needs a test rather
than a green pipeline. `scripts/tests/test-aws-pager-guard.sh` asserts the guard, that it is exported
(a plain shell variable would set the parent and change nothing for the child `aws` process), and —
the durable half — that **every** script calling the CLI is covered, with an explicit
exemption list checked in both directions. Everything else about v2 is drop-in here: `None` for a
null `--output text`, JMESPath `sort_by`/`starts_with`, `ecr get-login-password` and
`--secret-string file://` all behave identically, and nothing in this repo passes a blob argument
that `cli_binary_format` would change.

## `watch-aws-progress.sh`

**`scripts/watch-aws-progress.sh <apply|destroy>` narrates the AWS side while Terraform sits on
"Still creating/destroying".** Run in the background by `deploy.sh` step 6 and `destroy.sh` step 7
(both killed by their `EXIT` trap; `VOTEBALL_NO_WATCH=1` disables it), it polls the AWS API and prints
only *changes*: EKS/RDS/node-group state, ASG launch activities, EC2 **status checks**
(`initializing → ok`, the closest thing AWS publishes to "the OS booted"), the RDS event stream, then
node `Ready` and the ten Helm releases landing. On destroy it adds the final snapshot's
`PercentProgress` and the ENI count that pins the subnet. Three properties are load-bearing and are
what `scripts/tests/test-aws-progress-watch.sh` actually asserts:
- **It is read-only and must stay that way.** It runs *concurrently with a live destroy*, so the test
  records every operation the stubbed CLI is asked to run and fails on any verb that is not
  `describe*`/`list*`/`get*`. The single write is `eks update-kubeconfig`, pinned to a throwaway file
  in the script's own temp dir — it must never touch `~/.kube/config`, which is step 7's job.
- **It must never exit non-zero.** It is backgrounded inside `set -euo pipefail` in front of a billed
  ~13-minute apply; every call is guarded, and the script is deliberately not `set -e`.
- **It is a separate process writing to the same terminal, never a pipe.** Piping the apply through
  anything would put `tee`/`PIPESTATUS` between the caller and Terraform's exit code — the exact
  failure mode `destroy.sh`'s own comment warns about.
Note the EKS **control plane** exposes one field (`CREATING`/`ACTIVE`) and nothing more — those ~8
minutes cannot be broken down further, so don't add a probe trying to. The node instances are launched
by the EKS-managed ASG, not Terraform, so the provider's `default_tags` never reach them: filter on
`tag:eks:cluster-name`, not `Project`.

## CI/CD scripts (`scripts/ci/`, `scripts/jenkins/`) and the script test suite

**Fourteen scripts** (count them: `ls scripts/ci/*.sh | wc -l` — this number has been wrong three
times now: it said "Five" while the directory held eight, was corrected to "Twelve" only to be stale
again within the same session because `verify-deployed-image.sh` landed an hour later, and said
"Thirteen" until `changed-paths.sh` landed on 2026-09-08. Derive it, do not read it from here), each one pipeline decision point extracted so it can be tested without
triggering a real build. Five were added on 2026-08-23 by the review pass:
`promote-to-release.sh` (builds each `release` commit with `git read-tree`, never a merge — see the
design doc), `resolve-digests.sh` (tag → the four image digests, authoritative because the ECR repos
are `IMMUTABLE`), `current-release-tag.sh` (what is deployed right now, for the chart-only path) and
`notify.sh` (SNS on the NEEDS A HUMAN branches; can never fail a build) and
`verify-deployed-image.sh` (CD Verify — matches the running image's DIGEST against what the tag
resolves to, falling back to the tag only when no digest is pinned; it was inline in Jenkinsfile-cd
and rolled back a healthy release because it still matched on `:tag` after the chart moved to
digests). `should-skip-build.sh` (G2, the `[skip ci]` loop guard) and `images-exist.sh` (G1, the
immutable-tag re-run check) hold two of `Jenkinsfile-ci`'s decisions — `images-exist.sh` is also
reused, read-only, by `Jenkinsfile-cd`'s Input Validation stage to confirm a requested tag really is
in ECR before promoting it. `validate-repo.sh` is the CI Validation stage: asserts every
`services/*` context has a `Dockerfile` and `.dockerignore` and that no image is unpinned, before
anything is built. `smoke-test.sh` is the CD Smoke Test — the **only** check in the whole pipeline
that asks the product itself whether it works, rather than whether pods are Healthy; reads
`SMOKE_BASE_URL` and retries with backoff against `/`, `/api/options` and `/api/results?by=all`, and
deliberately **not** `/health` (that's the in-cluster probe target — nginx proxies only `/api/*`, so
it 404s publicly — and it's already what ArgoCD's health check runs). `previous-tag.sh` reads the
prior `image.tag` from `values.yaml`'s git history — what rollback targets. **Its grep requires a
QUOTED tag (`tag: "…"`).** An escaping bug that wrote the tag unquoted disarmed rollback silently on
2026-08-04: it returned a frozen tag forever and nothing caught it, because the hand-written test
scaffold always used quotes — `test-sync-values.sh` now carries an unquoted-tag regression case for
exactly this reason.

```bash
scripts/tests/run-ci-suite.sh         # runs all of the below that work offline — what CI executes
scripts/tests/test-ci-guards.sh       # should-skip-build.sh / images-exist.sh; stubs ECR via CI_STUB_DESCRIBE_CMD
scripts/tests/test-validate-repo.sh
scripts/tests/test-smoke-test.sh
scripts/tests/test-build-push-ecr.sh  # the dirty-tree guard; extracts the block, no docker/AWS
scripts/tests/check-jenkinsfile-shell.sh   # see below — not a guard test, a shell-syntax gate
scripts/tests/test-promote-to-release.sh   # the release-branch mechanics; GIT_GROUP, real throwaway repos
scripts/tests/test-jenkins-plugin-lock.sh  # plugins.txt / plugins.lock.txt / Dockerfile stay in step
scripts/tests/test-notify.sh               # the SNS notifier can NEVER fail a build
scripts/tests/test-refresh-api-cidr.sh     # the EKS API allow-list helper; its refusals and
                                           # already-covered no-ops are the point, not the happy path
scripts/tests/test-verify-deployed-image.sh # CD Verify: match the DIGEST, not the tag
```

**Do not read the suite's size from this file — derive it:**

```bash
scripts/tests/run-ci-suite.sh | tail -1       # "PASS — all N script tests green [group: all]"
# N counts the tests it RAN. The SKIP array holds the rest; N + ${#SKIP[@]} + 1 (the runner itself)
# equals `ls scripts/tests/*.sh | wc -l`, because the three lists are exhaustive.
```

This sentence used to state a number ("26 tests as of 2026-08-25") and it was wrong within two days —
the runner printed 27 while this file still said 26, which is precisely the drift the paragraph
warned about and then committed. `PYTHON_GROUP`, `GIT_GROUP` and `SKIP` are exhaustive and the runner
fails if a file in `scripts/tests/` appears in none of them, so the count moves whenever a test is
added and any number written here is stale by construction.

**`Jenkinsfile-ci`'s "Script tests" stage runs `run-ci-suite.sh` in TWO containers, and until
2026-08-11 nothing ran these tests at all** — CI ran `pytest` for `services/{backend,worker}` and stopped, so every guard
protecting the pipeline itself was covered by a test somebody had to remember to run. Any of them
could have been deleted with every build staying green. **`run-ci-suite.sh`'s `PYTHON_GROUP`,
`GIT_GROUP` and `SKIP` lists are exhaustive and it fails if a test file appears in none of them —
whichever group is being run**, so a new test cannot slip through the gap between the two groups, and
adding one forces a one-line decision. A glob would silently pick up a future helm-dependent test and
break every build; an unchecked hand-list would silently drop a new test and protect nothing. It also
fails if a listed test no longer exists. Several are skipped for tools the agent lacks (`helm`, `gh`, `curl`) — count the
`SKIP` array in `run-ci-suite.sh` rather than trusting a number here; it said "three" while the array
held five. Moving one into a group means adding that tool to an image, not loosening the test. The
`helm` entries are the widest gap: nothing in CI renders `charts/logging` or `charts/jenkins-support`.

**The split exists because no container in the `voteball-build` pod has both `python3` and `git`** —
`python:3.12-slim` has python3 and no git; the default `jnlp` container has git (it performs the
checkout) and no python3. So `run-ci-suite.sh git` runs in jnlp and `run-ci-suite.sh python` runs in
`container('python')`. Build #7 established this the expensive way: the whole suite ran in jnlp and
four tests died on `python3: command not found`. **Determine a test's group by running it in a bare
image, never by reading it** — several mention `aws` and `terraform` only in comments and stub
variables, which is exactly how that build went wrong.

**`build-push-ecr.sh` refuses to build from a dirty working tree**, because it tags images
`git rev-parse --short HEAD` and an image built from unstaged work would carry a tag that does not
describe its contents — with **nothing downstream to catch it**: ArgoCD syncs it, the smoke test
passes, and CD's `release: <sha> (image tag <tag>)` commit records the wrong provenance permanently.
Near-missed on 2026-08-11, when revision 18's `seed.sql` was uncommitted as `deploy.sh` reached the
image step and would have shipped as `b9e3054`. The guard runs **before** the terraform-state read
and the ECR login, so it costs no network and fails at deploy step 5 — ahead of the billed apply at
step 6. `ALLOW_DIRTY_BUILD=1` overrides it but suffixes the tag `-dirty`, so the escape hatch cannot
produce a lying tag either. Untracked files count (docker's build context includes them);
gitignored files do not. **`terraform/.terraform.lock.hcl` is the one exemption**, added 2026-09-02
because the deploy dirties its own tree: step 2's `terraform init -upgrade` rewrites that file
whenever a provider moves (`hashicorp/tls` 4.3.0 → 4.4.0), and step 5 then refused, killing the run
~4 minutes in and forcing a manual commit plus a restart from step 1. It is safe for exactly one
reason — the file is in none of the docker build contexts, so it cannot change a byte of any image
and cannot produce the lying tag the guard exists to prevent. **Do not widen it to `terraform/`**:
`test-build-push-ecr.sh` now fails if you do, a check added only because mutation-testing showed the
first version of that test passed happily against the widened pathspec.

Same offline-stub pattern throughout. **Extend the matching test whenever you change a script** —
pipeline logic that can only be tested by running the pipeline is exactly what this project refuses
to accept. The two G1/G2 guards deliberately fail safe in *opposite* directions (skip vs rebuild);
that asymmetry is intentional, don't "make them consistent".

**`check-jenkinsfile-shell.sh` exists because the Jenkins Declarative linter validates pipeline
SCHEMA only** — stage/when/steps nesting — and never looks inside an `sh '''…'''` body. On
2026-08-04 a shell script that didn't even parse passed the linter, this repo's own structural
check, *and* manual review. This script globs `Jenkinsfile-*`, extracts every `sh '''…'''` body
(including the inline `sh(script: '''…''')` form), applies Groovy's own single-quoted-string
unescaping (Groovy, not bash, is what actually receives the raw file text), and runs `bash -n` on
the result — testing the raw text instead was confirmed to check a string bash never sees. It also
rejects apostrophes, backticks and double quotes inside shell comments in those blocks, after a
quoting failure in one such comment cost a full debugging cycle that was never root-caused.

`scripts/jenkins/` holds five thin wrappers over the `terraform apply -target=...`/`destroy
-target=...` calls that own the Jenkins release — **not** a second install path, for the same reason
there's no `helm upgrade` path for the app chart. `install-jenkins.sh` and `uninstall-jenkins.sh` are
the obvious two. `configure-jenkins.sh` pushes a JCasC/plugin/credential/job change to the running
controller (the step people forget: committing `ci/jenkins/jenkins.yaml` alone is a no-op) and then
greps the controller log for `unresolved variable`, failing on a hit — JCasC does **not** crash on
one, it defaults the value to an empty string and boots, so nothing else catches it; `--restart`
covers a *new key* in `voteball/jenkins`, which `containerEnvFrom` projects only at pod start.
**`create-jobs.sh` deliberately creates no job** — jobs come from the `jobs:` block of
`ci/jenkins/jenkins.yaml` (Job DSL) and a second creation route would be a competing source of truth
that JCasC erases on the next boot; the script asserts the result instead (both declared, both loading
their `Jenkinsfile` from SCM not inline, exactly two live, `--repo-only` for the cluster-free half).
Both exist under the names the course brief's §2 lists, so a reader looking for them finds the real
mechanism rather than nothing.
`verify-jenkins.sh` asserts rather than prints: among other checks, that **exactly two** jobs exist
(JCasC's Job DSL never deletes a job it stops declaring, so a stale one survived the CI/CD split and
had to be removed by hand) and that the `jenkins-cd-agent` ServiceAccount cannot write to
`devops-app` (ArgoCD must stay the only applier). `VERIFY_STRICT=1` turns a skipped check (e.g. no
credentials available) into a failure — use it whenever the output is being captured as evidence,
since a permissive skip looks identical to a passing check in a log.
