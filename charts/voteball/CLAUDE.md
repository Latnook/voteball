# charts/voteball — CLAUDE.md

Guidance for the Helm chart. The root `CLAUDE.md` carries the project-wide rules, including the
warning that **`values.yaml`'s `image.tag` is written by `scripts/sync-values-from-tf.sh` and must
never be hand-edited**, and that the nine environment-identity fields beside it are
`REPLACED-BY-ARGOCD` placeholders filled by the ArgoCD Application's `helm.parameters`, not by this
file.


```bash
helm lint charts/voteball
helm template voteball charts/voteball --namespace devops-app   # renders without a live cluster
```

**The migration Job is a `post-install,pre-upgrade` hook, and that split is deliberate.** As
`pre-install` it cannot work at all: pre-install hooks run before every normal chart resource, so the
ServiceAccount, ConfigMap and ExternalSecret it needs do not exist yet, and it fails with
`serviceaccount "backend" not found` after burning `activeDeadlineSeconds`. A fresh install has nothing
to order (the schema is built from nothing and `init_db` is idempotent); an upgrade does, and by then
every dependency exists. Its pod is labelled **`app: migrate`, never `app: backend`** — the backend
Service selects that label and would route live HTTP to a one-shot script — and `migrate` is listed in
the `allow-db-egress` NetworkPolicy so it can still reach RDS through the default-deny.

**All three Deployments carry startup, readiness and liveness probes, and the three are sized
independently on purpose — do not normalise them.** Four rules that are not obvious from reading the
YAML:

- **Never re-add `initialDelaySeconds` to a readiness or liveness probe here.** A startup probe
  *suppresses* both — neither is scheduled until it passes — so an initial delay on them is dead
  config that reads like a live tuning knob. The boot window is owned entirely by
  `failureThreshold × periodSeconds` on the startup probe, and that product is a hard wall: exceed it
  and the kubelet kills the container with 10s→5min backoff.
- **Liveness on frontend/backend is a `tcpSocket` check, deliberately weaker than readiness.** Don't
  "improve" it to hit `/health`. Readiness going false removes one pod from the Service; liveness
  going false *kills* it, so a liveness probe that touched the database would turn one RDS blip into
  a simultaneous crash loop across every replica. For the same reason `/health` itself must stay a
  static response that opens no connection.
- **The worker's 120s staleness threshold lives inside the `test` expression, not the schedule.** Its
  probes only begin failing once `/tmp/heartbeat` is already 120s stale, so the real time-to-kill is
  120s + `failureThreshold × periodSeconds` ≈ 3.5 min — not the 90s the schedule suggests. Budget
  from the sum, and remember all three probes `stat` that path independently (see
  `docs/eks/ro-fs-writable-paths.md`).
- **The worker's probes set `timeoutSeconds: 3`, not the default 1.** Each forks `sh` + `date` +
  `stat`, and an exec probe that times out counts as a **failure** — on a CPU-throttled Spot node the
  default would kill a perfectly healthy worker for being slow to fork.

The per-workload numbers and the reasoning behind each are in `docs/eks/architecture.md` §2
("Health checking"); `docs/eks/live-cluster-snapshot.md` shows the *pre-2026-08-06* probe config and
is frozen evidence — don't "correct" it.

**Every new workload's pod label must be added to whichever egress NetworkPolicy grants what it
actually needs, and the label is the *workload* name, not the CronJob/Job/image name.** The namespace
is default-deny; a pod named by no egress policy keeps only `allow-dns-egress`, so DNS resolves and
every TCP connection is silently dropped — RDS and the AWS APIs alike. The backup CronJob shipped
labelled `app: voteball-backup` while the policy listed `backup`, and its nightly pg_dump was broken
from 2026-07-19 until 2026-07-31 (fixed in `1bda7b5`).

There were four egress policies since 2026-08-23, not one — pick by what the workload needs:

| Policy | Selects | Grants |
|---|---|---|
| `allow-db-egress` | backend, worker, backup, migrate | `10.0.0.0/16` TCP **5432** (RDS) |
| `allow-frontend-to-backend-egress` | frontend | `172.20.0.0/16` + `10.0.0.0/16` TCP **5000** |
| `allow-aws-api-egress` | worker, backup | `0.0.0.0/0` TCP **443** (SNS, S3, STS) |
| `allow-canary-egress` | canary | `0.0.0.0/0` TCP **443** (the public ALB) |

They are additive, so `worker` gets the union of the first and third. **`scripts/ci/validate-repo.sh`
fails the build** if a pod template carries an `app:` label that no egress policy selects — four
selectors are four chances to forget, which is why that gate exists rather than this paragraph.

**That class of bug does not fail cleanly, it fails *flakily*, so do not conclude from one green run
that a new pod's egress is allowed.** The VPC CNI runs `NETWORK_POLICY_ENFORCING_MODE=standard`,
which fails **open** until the node's policy agent programs the pod's eBPF maps — observed taking
well over 30s under load. Anything connecting in that window succeeds regardless of policy, which is
why `pg_dump` (connects in milliseconds) always worked while the aws-cli (seconds of Python startup
before its first STS call) did not, and why `docs/eks/live-cluster-snapshot.md` legitimately records
`Completed` backup pods that the policy never permitted. To test egress honestly, sleep at least a
minute inside the pod before opening the socket, or check the rendered label against the policy list
instead of testing at all.

**`_helpers.tpl` output may never reach a `selector`, and never a pod template's labels.** A
Deployment's `spec.selector.matchLabels` is immutable after creation: route a helper into it and the
next chart-version bump changes the rendered label, ArgoCD's sync fails with a field-immutable error
rather than rolling, and the only fix is deleting the Deployment in production. The same helper in a
pod template would silently roll every replica on each version bump. So `voteball.labels` is applied
to **object** metadata only, and the selectors stay the plain literal `app: <component>`. The way to
prove a helper change is safe is `helm template` before and after, diffed — a pure refactor
(`voteball.image` was one) shows *no* diff at all.

**Alert rules must carry `release: kube-prometheus-stack`.** Without that label the PrometheusRule is
created, looks correct in `kubectl get prometheusrules`, and is silently never evaluated. Only write
rules against metrics this cluster actually exposes (kube-state-metrics): RDS, ALB and ACM figures are
CloudWatch-only and nothing scrapes them into Prometheus, so such rules could never fire — worse than no
rule, because the coverage looks complete.

ArgoCD owns this release in the cluster (`argocd/voteball-application.yaml.tmpl`, rendered by
`scripts/render-argocd-app.sh` — do not `kubectl apply` the template directly), so **changes reach the
cluster by going through `application-cd`, which promotes them to the `release` branch** — not by
committing to `master` (which no longer deploys anything on its own) and not by running `helm upgrade`
by hand. If you do install manually, note ArgoCD's `selfHeal` will fight you — concretely, a manual
`helm upgrade` of a chart that **differs** from what ArgoCD has applied fails with
`conflict with "argocd-controller"` on server-side-apply field ownership. Upgrades go through git.

**Never write an empty list literal (`to: []`, `imagePullSecrets: []`) in a template.** The API server
drops it on write, so the value Helm applies can never equal the value stored — and since both Helm
(`deploy.sh` step 10, on a fresh cluster) and ArgoCD apply this chart server-side, that mismatch conflicts against
whichever manager owns the field on *every* upgrade, even though the chart is otherwise identical.
One `- to: []` in `allow-dns-egress` failed a deploy this way on 2026-08-10. An omitted field and an
empty list mean the same thing to Kubernetes here, so omit it; an empty **map** (`podSelector: {}`) is
meaningful, is preserved, and is fine. `scripts/ci/validate-repo.sh` gates this in CI.

**Adding a CLUSTER-SCOPED resource to this chart takes two commits, not one.** Since 2026-08-03 the
Application runs in the `voteball` AppProject, whose `clusterResourceWhitelist` is empty — every kind
this chart renders today is namespaced, so nothing cluster-scoped is permitted. Add a `ClusterRole`,
`ClusterRoleBinding`, `CRD` or `StorageClass` and the chart still lints, still templates, and ArgoCD
refuses the sync with `resource ... is not permitted in project voteball` — an error that reads like an
ArgoCD fault rather than a missing whitelist entry. Whitelist the kind in
`argocd/voteball-application.yaml.tmpl` first. That friction is the point: cluster scope should be a
deliberate, reviewable act.

## seccomp and the ALB TLS policy (2026-09-09)

Every container `securityContext` here carries `seccompProfile: { type: RuntimeDefault }` alongside
`allowPrivilegeEscalation: false`; `scripts/tests/test-hardening.sh` counts the two and fails the build
when they differ, so **a new container needs both lines**. It completes the Pod Security Standards
"restricted" set the chart already met otherwise.

`ingress.yaml` sets `alb.ingress.kubernetes.io/ssl-policy`. It is an **Exclusive** annotation across
the shared `voteball` ALB group (`charts/jenkins-support` and `charts/logging` are the other two
members): the values must be byte-identical or the controller errors the whole group and stops
reconciling all three. Change it in all three files in one commit; the test asserts they match.

## The synthetic canary and what the SLIs depend on

*Moved verbatim from the root `CLAUDE.md` on 2026-10-02 so it loads only when working here. Where a paragraph says "above" or "below" about something not in this file, it is in one of: `terraform/CLAUDE.md`, `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`, `charts/observability/CLAUDE.md`, `charts/voteball/CLAUDE.md`, or the `voteball-cicd` skill.*

**The synthetic canary Deployment (`charts/voteball/templates/canary-deployment.yaml`, gated on
`.Values.canary.enabled`) is not a nice-to-have — it is what makes every ratio-based SLI on this site
meaningful at all.** Voteball has close to no organic traffic, so an outage with zero requests in
flight makes the availability ratio's numerator and denominator vanish together, and its `or vector(1)`
"no data" fallback then reports a confident, wrong `1` — the same 2026-08-18 drill found this exact
failure. The canary hits the real public voting journey every `canary.intervalSeconds` (30s) purely to
guarantee the ratio always has a real denominator to divide by. **Disabling the canary does not just
remove one metric source — it silently makes `voteball:availability:ratio5m` untrustworthy again, and
it makes `VoteballJourneyTrafficStopped` meaningless with it**, since that alert only means something
against traffic guaranteed to exist; without the canary, zero requests is this site's normal state, and
the alert would either fire constantly or (worse) be tuned so loose it catches nothing. The two are
coupled on purpose — see the comment at `VoteballJourneyTrafficStopped` in
`charts/voteball/templates/prometheusrule.yaml`.

**The canary can be alive, healthy and resolving nothing — and that reads as 100% availability.**
On a rebuild, app pods start and look up `<app_domain>` *before* external-dns has created its A
record. Because that name already exists in Route53 for unrelated reasons (a `google-site-verification`
TXT record), the answer is **NOERROR with no A record**, not NXDOMAIN — a negative answer, and
RFC 2308 caps how long it may be cached at `min(SOA record TTL, SOA MINIMUM)`, which for
`latnook.com` is `min(900, 86400)` = **15 minutes**. Four live documents said 86400 / twenty-four
hours (the MINIMUM field alone) until 2026-08-26; `docs/eks/live-cluster-snapshot.md` had the rule
right the whole time, which is the usual tell — *a doc contradicting another doc*. **Which cache
holds it decides whether anything you can do helps**: CoreDNS caps a denial at 30s, so restarting it
clears its copy cheaply, while the **VPC resolver upstream keeps its own for the full 15 minutes and
no restart in this cluster can touch it** (measured 2026-08-26 mid-rebuild: 19s left on CoreDNS,
691s left on `10.0.0.2` — so the restart could not have worked, and the script's three retries over
30s were never going to be enough). The canary sends nothing,
`voteball:journey_requests:rate5m` sits at 0, and `voteball:availability:ratio5m` falls back to
`or vector(1)` — a confident, wrong 100%, on a site whose users are unaffected because the *public*
path works fine. The tell is **TXT resolves and A does not**. `deploy.sh` step 11c runs
`scripts/verify-public-dns.sh`, which restarts CoreDNS **only** when a public resolver can resolve a
name the cluster cannot; an unconditional restart would be a step nobody could safely remove. **That
"public resolver" must not be the machine's own stub resolver** — it caches the same NODATA for the
same reason, so `getent` reports "the record does not exist yet" about a record that plainly does and
the script then refuses to act (2026-08-26: `systemd-resolved` held the negative while `dig @1.1.1.1`
returned both ALB addresses from the same shell). It now asks the zone's **authoritative**
nameserver, which has no cache to be wrong.
`VoteballJourneyTrafficStopped` does catch this on its own after 10 minutes — it went `pending` six
minutes into the 2026-08-24 occurrence — but an alert that fires on every deploy is one people learn
to ignore.

## Gating chart resources that reference Terraform-created objects

**Any chart resource that references a Terraform-created object must be gated off by default.**
Chart code reaches the cluster on a `git push` (CI → CD → ArgoCD, minutes, automatic); the Terraform
object it names reaches AWS only on a billed `terraform apply` that a human runs. Those are two
different speeds, and shipping the consumer first is a race the consumer wins. The blast radius is
much larger than the feature involved: External Secrets Operator cannot resolve the reference, so the
resource is Degraded, so **ArgoCD's whole sync operation reports `phase: Failed`** — and because
anything failing after `application-cd`'s Promote stage triggers an automatic rollback, every CD run
becomes *deploy fails → roll production back*. Hit for real on 2026-08-24: four consecutive failed CD
runs rolling production back to a stale tag while `master` moved ahead, caused by an ExternalSecret
naming a Secrets Manager container `terraform apply` had not yet created. The gate
(`.Values.externalSecret.grafanaEnabled`, `.Values.externalSecret.enabled`) is flipped on only after
the apply *and* the seed script have run — see
`docs/design/2026-08-24-grafana-datasources-design.md`'s "Verification outcome". The repo already had
this shape and nobody had named it: `app-secret` reads a container Terraform creates empty and
`seed-eks-secret.sh` fills, and it never broke only because it had always been seeded before anyone
looked.

**A gate that is off in git is a rebuild that does not work.** The corollary nobody wrote down until
a real destroy/deploy cycle on 2026-08-25: gating a chart resource off protects a *running* cluster,
but if the gate ships `true` and nothing seeds the secret it references, every fresh deploy
reproduces the outage the gate was added to prevent. So a gated resource needs BOTH halves —
`scripts/deploy.sh` step 3c seeds `voteball/grafana` **before** the billed apply (alongside the app
and Jenkins secrets, and for the same reason), and the gates ship `true` because the seed step makes
that safe. Adding a gated resource without a seeding step is half a change.

**Environment variables are projected into a pod at START and never again.** `envFromSecret` on
Grafana, `containerEnvFrom` on Jenkins — same mechanism, same trap, hit twice. A pod older than its
Secret has the variable **unset**, and Grafana expands an unset variable in a provisioning file to an
**empty string** rather than erroring, so it authenticates with an empty password and fails at panel
load with `SQLSTATE 28P01`. `scripts/restart-grafana-datasources.sh` (deploy step 11d) handles it:
it **waits** for the Secret rather than checking once — on a fresh deploy the single check ran ~90
seconds before ESO filled it — then restarts and **verifies the variable is actually set** rather
than assuming the restart worked.
