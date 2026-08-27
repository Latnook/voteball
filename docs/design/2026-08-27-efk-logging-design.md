# EFK logging on EKS (Elasticsearch / Fluentd / Kibana)

**Date:** 2026-08-27
**Status:** designed, not yet implemented
**Supersedes:** nothing. It *adds to* `2026-08-17-observability-design.md` rather than replacing any
part of it — Prometheus/Grafana keep owning metrics, CloudWatch Logs keeps receiving pod logs, and
this doc only adds a second log destination and a search UI.

## Why

The course brief requires an **EFK stack, named explicitly**. That naming requirement is the whole
reason this doc exists, and it eliminates two options that would otherwise win on cost:

- **Amazon OpenSearch Service is out.** AWS forked Elasticsearch in 2021; the managed service ships
  *OpenSearch* and *OpenSearch Dashboards*, so a graded check for "Elasticsearch" and "Kibana" finds
  neither. Nothing errors — the substitution is silent, which is the same failure shape this repo
  already documents under "a NAME that is a silent contract with something off-screen".
- **Loki is out**, despite being the better engineering fit here (no PVC, chunks in the S3 bucket that
  already exists, ~256 MiB, survives Spot reclaim natively, and Grafana is already deployed with six
  dashboards). The brief's bonus line reads "CloudWatch/Loki logging" and the assignment asks for EFK;
  the assignment wins.

**"EFK" also constrains the F.** This cluster already runs **Fluent Bit** as a DaemonSet
(`terraform/addon-cloudwatch.tf`) — a different project from Fluentd (C, ~450 KiB, no Ruby plugin
ecosystem) that merely speaks the same protocols. Shipping Fluent Bit alone and calling it EFK is the
same silent-substitution risk as the OpenSearch case.

## Decisions

### 1. ECK operator, installed by Terraform — not by hand

The `eck-operator` Helm chart (pinned **3.5.0**, verified current against `helm search repo
elastic/eck-operator --versions` on 2026-08-27) installs into `elastic-system` and brings **17
cluster-scoped objects**: 12 CRDs, 3 ClusterRoles, 1 ClusterRoleBinding, 1
ValidatingWebhookConfiguration. The operator's own StatefulSet requests 100m/150Mi and already runs
`runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` — it meets this
repo's container-security bar with no overrides.

It goes in **`terraform/addon-eck.tf` as a `helm_release`**, the same class as ESO, external-dns,
ArgoCD and kube-prometheus-stack. This repo's boundary rule is that platform reaches the cluster by
`terraform apply` and configuration on top of it by `git push`.

**Why not run the commands by hand**, as suggested: this cluster is destroyed and rebuilt routinely.
A hand-run release is invisible to Terraform, so it silently disappears on every rebuild and has to be
retyped; worse, `destroy.sh` pre-uninstalls a known list of releases while the cluster is still
healthy, and an unknown fourth release owning a ValidatingWebhookConfiguration is exactly the shape
that hangs teardown (see decision 7).

**Downside:** a chart-version bump now costs a billed `terraform apply` instead of a one-line
`helm upgrade`. That is the same trade already accepted for every other add-on.

### 2. ArgoCD cannot own the operator, and that is the AppProject working correctly

The `voteball` and `observability` AppProjects both set `clusterResourceWhitelist: []` — a deliberate
blast-radius limit. The 12 CRDs are cluster-scoped, so the operator is structurally ineligible. The
`Elasticsearch`, `Kibana` and Fluentd objects are namespaced and therefore *are* eligible.

So the split is: **operator via Terraform, custom resources via a chart.** A new
`charts/logging/` gets a **third** ArgoCD `Application` + `AppProject` pair, declared in
`argocd/voteball-application.yaml.tmpl` alongside the existing two. This is not optional —
`scripts/render-argocd-app.sh --check` fails on any live `Application` this repo does not declare.

### 3. Sized from measured log volume, so no third node

The constraint is a hard one from the repo owner: **do not add a node.** Measured live on 2026-08-27,
before any change:

| Node | AZ | Memory requested | Free | CPU free |
|---|---|---|---|---|
| `ip-10-0-41-153` | il-central-1a | 1119Mi / 7080Mi (15%) | ~5.8 GiB | ~1255m |
| `ip-10-0-58-197` | il-central-1b | 2063Mi / 7101Mi (29%) | ~4.9 GiB | ~1165m |

The usual "Elasticsearch wants 4 GiB" figure is a default for real workloads. This is not one.
`addon-cloudwatch.tf` records ~3.1 GB/day across all namespaces with `ci`/`argocd`/`monitoring` at
~95% of it, and Fluent Bit is already scoped to `devops-app` alone — so the ingest rate is
**≈150 MB/day**, and a 7-day index is ~1 GB. One index, one shard, no replica.

| Component | Owner | Placement | Requests | Limits |
|---|---|---|---|---|
| `eck-operator` | Terraform | `elastic-system`, either node | 100m / 150Mi | 1 / 1Gi (chart default) |
| `Elasticsearch` (1 node, 1 GiB heap) | `charts/logging` | pinned to 1a by its EBS volume | 300m / 2Gi | 1 / 2Gi |
| `Kibana` | `charts/logging` | 1b, anti-affinity from Elasticsearch | 200m / 1Gi | 500m / 1Gi |
| `Fluentd` aggregator | `charts/logging` | 1b | 100m / 256Mi | 500m / 512Mi |
| ILM bootstrap Job (transient, post-install hook) | `charts/logging` | either node | 50m / 64Mi | 200m / 128Mi |
| **Total added** | | | **750m / 3542Mi** | |

**The two halves of that total are measured by different things, and confusing them cost a review
cycle.** `helm template charts/logging` sees **650m / 3392Mi** — the four chart rows, ILM Job included.
The `eck-operator`'s 100m / 150Mi is installed by `terraform apply` and is invisible to the chart. An
earlier version of this table read 700m by including the operator *and* omitting the ILM Job, while
`scripts/tests/test-logging-chart.sh` compared the chart's own sum against a 700m cap — two different
sets, the same number, neither checking the other. The test's cap stays where it is (it is the right
bound for the chart) but now says explicitly that it is the **chart's share**, and prints the feature
total alongside it.

Re-measured against live node headroom on 2026-08-27 (`kubectl describe node`, allocatable 1930m /
~7080Mi per node), with Elasticsearch on one node and Kibana + Fluentd + the operator on the other:

| Node | Requests now | With EFK | Free after |
|---|---|---|---|
| `ip-10-0-41-153` (1a) | 650m / 1055Mi | 1000m / 3167Mi | ~930m, **~3.8 GiB** |
| `ip-10-0-58-197` (1b) | 680m / 1887Mi | 1080m / 3317Mi | ~850m, **~3.7 GiB** |

Both stay above the ≥3.5 GiB-per-node line the CI spike needs, so **no third node is implied** — which
is the property that matters, since requests are what the scheduler and Cluster Autoscaler read.

**The binding constraint is the CI spike, not EFK.** A `voteball-build` agent pod requests ~3 GiB
(BuildKit alone is 2Gi) and ~1000m on whichever node it lands. EFK is therefore **spread** across both
nodes rather than stacked, leaving ≥3.5 GiB free on each. This is enforceable rather than hopeful:
requests are what both the scheduler and Cluster Autoscaler read, so keeping the sum under that line
is what stops CA quietly adding the node we said we would not add.

**Downside:** a single Elasticsearch node means no replica shard, so the cluster health is **yellow by
design, never green**, and a lost volume loses the logs. Both are acceptable — the logs are a
convenience copy, CloudWatch still holds the authoritative one (decision 5), and alerting must
therefore not page on "not green" (decision 9).

### 4. `node.store.allow_mmap: false` instead of a privileged init container

Elasticsearch requires `vm.max_map_count` at 262144, above the EKS AMI default. **ECK's default remedy
is a privileged init container** that sets the sysctl on the host. That would be the second privilege
exception in this repo after BuildKit — and unlike BuildKit's, it is avoidable.

Setting `node.store.allow_mmap: false` in the `Elasticsearch` CR makes Lucene use `niofs` instead of
`mmapfs`, removing the sysctl requirement entirely. Every container in this stack then keeps
`allowPrivilegeEscalation: false` and there is no host-level dependency at all.

**Downside:** `niofs` is measurably slower than `mmapfs` on large indices, because reads go through
syscalls rather than page-cache-backed memory maps. At ~1 GB the difference is not observable, and the
alternative — a privileged container to speed up a log search nobody runs hot — is a bad trade. If the
index ever grows past a few GB, revisit this before revisiting the node count.

### 5. Fluent Bit fans out; it does not switch

`addon-cloudwatch.tf` gains a **second `[OUTPUT]`** (`forward`, to the Fluentd Service) beside the
existing `cloudwatch_logs`. CloudWatch keeps receiving everything, so the Grafana CloudWatch datasource
built on 2026-08-24 keeps working and the authoritative log copy is unchanged.

**That file's existing warning applies directly:** the `fluent_bit_application_log_conf` string
*replaces* the add-on's default `application-log.conf` rather than merging into it, so a malformed or
omitted `[OUTPUT]` block fails silently — Fluent Bit stays healthy and ships nothing. The new block
must be verified by counting documents that actually arrive in Elasticsearch, not by the pod being
Running (decision 10).

**Downside:** every log line is now stored twice and billed once (CloudWatch ingestion is unchanged;
the Elasticsearch copy is on an EBS volume we already pay for). Dual output also doubles Fluent Bit's
buffer pressure, which at 150 MB/day is immaterial against its 50MB `Mem_Buf_Limit`.

### 6. Storage: `gp3`, and what Spot reclaim actually does

The `gp3` StorageClass already exists (`ebs.csi.aws.com`, `WaitForFirstConsumer`,
`allowVolumeExpansion: true`, reclaim `Delete`). The Elasticsearch CR's `volumeClaimTemplate` asks for
**20Gi** — 20× the expected 7-day index, sized so ILM has room to misbehave without filling the disk.

`WaitForFirstConsumer` means the volume is created in whichever AZ the pod is first scheduled to. From
then on the PV carries `nodeAffinity` on `topology.ebs.csi.aws.com/zone`, and **the scheduler honours
it** — so after a Spot reclaim the pod is placed back into that same AZ. It goes `Pending` only if
that AZ has no schedulable node at that moment; with `min_size: 2` across two AZs the ASG normally
replaces it there. This is a temporary-unavailability risk, not the permanent `Pending` that EBS-backed
`JENKINS_HOME` would have been.

**EFS is not an option here**, which is why this differs from the Jenkins decision: Elastic does not
support NFS-backed data paths (file locking and latency), and running Elasticsearch on EFS is a known
corruption footgun. So the AZ-lock is accepted rather than engineered around.

Reclaim policy stays `Delete`, matching every other volume in this stack — the logs die with the
cluster, deliberately.

### 6b. Retention: ILM at 7 days, and why it is not optional

Index Lifecycle Management is available under Elasticsearch's free **Basic** licence, which is what
ECK installs by default. The chart ships a single ILM policy — roll over daily or at 1 GB, delete at
**7 days** — plus the index template and write alias Fluentd targets.

**Without it a log store is a disk that fills.** The 20Gi volume in decision 6 buys about 130 days at
the measured rate, after which Elasticsearch flips the index to read-only via its flood-stage
watermark and ingestion stops — silently, from the writer's point of view. Seven days is chosen
because CloudWatch holds the authoritative copy (decision 5); Elasticsearch is the *search* surface,
not the archive.

**Downside:** anything older than a week is only in CloudWatch, so an investigation reaching further
back means Logs Insights rather than Kibana.

### 7. Teardown order, which is where this bites

`scripts/destroy.sh` step 4 pre-uninstalls this stack's own releases while the cluster is still
healthy — currently **four**: `voteball`, `jenkins`, `jenkins-support`, `kube-prometheus-stack`.
(Root `CLAUDE.md` says three; that is stale and is corrected in this change.)

ECK joins that step, **in a specific order**:

1. Delete the `Elasticsearch` and `Kibana` custom resources.
2. Wait for their pods to go.
3. `helm uninstall elastic-operator -n elastic-system`.

**Reversed, it hangs — because of FINALIZERS.** ECK attaches its own finalizers to the
`Elasticsearch`/`Kibana` resources and to the Secrets they own, and only the running operator removes
them; the operator is also what performs the orderly shutdown that `volumeClaimDeletePolicy` (below)
depends on. Uninstall it first and every CR delete sits `Terminating` with no controller left to clear
it — the same class as the `kubernetes_namespace.ci` finalizer hang of 2026-08-04.

**As designed this said the `ValidatingWebhookConfiguration` was the mechanism, and that is wrong.**
Rendering `eck-operator` 3.5.0 shows all 16 validating webhooks are `failurePolicy: Ignore` on
`operations: [CREATE, UPDATE]` — DELETE is never intercepted, and an unreachable webhook is *skipped*
rather than blocking, so the stated mechanism cannot occur at all. The wrong explanation had
propagated to `terraform/addon-eck.tf`, `scripts/destroy.sh` and root `CLAUDE.md`; all four now name
the finalizers. **The ORDER was never in question and does not change** — a plausible mechanism
attached to a correct conclusion is the harder kind of error to catch, since nothing misbehaves until
someone reasons from it.

ECK's `volumeClaimDeletePolicy` defaults to deleting the PVC when the Elasticsearch resource is
deleted, so the Elasticsearch volume needs no equivalent of the step-5 observability-PVC cleanup. This
is asserted by the teardown test rather than assumed.

### 8. Deploy ordering instead of a gate

`charts/logging` ships **`enabled: true`**. Nothing flips it — not `scripts/deploy.sh`, not the
`logging` ArgoCD Application (which passes no `helm.parameters`).

**As designed this shipped `enabled: false` with `deploy.sh` flipping it, and that was wrong twice
over.** No code was ever written to do the flipping, so the stack shipped permanently dormant: a fresh
deploy rendered zero objects, ArgoCD reported Synced/Healthy on an empty manifest, and the deploy
reported success — the same confident-and-empty failure shape this repo documents elsewhere. And the
gate was not needed in the first place.

The hazard the gate rule addresses is real: a chart resource that references a Terraform-created object
must not reach the cluster first, because chart code arrives on a `git push` (minutes, automatic) while
the object it names arrives only on an apply a human runs. That is the 2026-08-24 outage exactly — ESO
could not resolve a reference, the resource went Degraded, the whole ArgoCD sync reported
`phase: Failed`, and four consecutive CD runs rolled production back.

**Here the ordering already forecloses it, structurally.** The `Elasticsearch`/`Kibana` CRs reference
CRDs that `terraform apply` installs at deploy step 6, and the ArgoCD Application that syncs this chart
is not created until step 11. On a fresh cluster the CRDs always exist first. On an existing cluster
there is no `logging` Application at all until a deploy that ran both halves, so a push to `master`
cannot deliver the chart ahead of the apply even in principle.

So this follows the precedent CLAUDE.md already records for the Grafana datasource gates — *"the gates
ship `true` because the seed step makes that safe"* — with the deploy ordering playing the seed step's
role. The 2026-08-25 corollary is what rules out the alternative: **a gate that is off in git with
nothing to turn it on is a rebuild that does not work.** `values.yaml` still honours `enabled: false`
as a deliberate kill switch, and `scripts/tests/test-logging-chart.sh` asserts both directions — that
the shipped defaults render the stack, and that `--set enabled=false` renders nothing.

### 9. Exposure, access control and alerting

**Kibana** is published as `kibana.<app_domain>` on the existing ALB group `voteball`. A grouped ALB
de-provisions only when *no* member Ingress remains, so this becomes the **third** member alongside
`devops-app/voteball` and `ci/jenkins-webhook`, and `scripts/cleanup-stale-dns.sh` gains a third host
(`HOSTS` currently lists two).

Authentication is **ECK's built-in `elastic` user**, whose password the operator generates into a
Kubernetes Secret. No second auth system, no ExternalSecret, nothing new in Secrets Manager. The WAF
ACL already attached to the ALB covers it. TLS is ACM at the ALB, as for every other host.

**That certificate has to be created, and it was missed on the first pass.** `kibana.<app_domain>` is
not covered by any certificate in this account — ACM holds `latnook.com`, `voteball.latnook.com` and
`jenkins.voteball.latnook.com`, with no wildcard — so `terraform/addon-eck.tf` creates its own,
DNS-validated, mirroring `aws_acm_certificate.jenkins` in `addon-jenkins.tf` (its own certificate, not
a SAN on the app's, so `ingress.certificateArn` stays out of it and the sync script keeps owning ten
fields, not eleven). The chart's `certificateArn` stays **empty**: with no annotation the AWS Load
Balancer Controller discovers an ISSUED certificate matching the Ingress host, which is why this adds
no sync-managed field. **The failure it prevents is not scoped to Kibana** — a grouped Ingress is
reconciled as one model per group, so a member whose certificate cannot be resolved fails the group's
model build and stalls the ALB serving the public site and the Jenkins webhook alongside it.

**Alerting** adds two rules to `charts/observability`, both built on kube-state-metrics — no new
exporter:

- `ElasticsearchDown` — the Elasticsearch pod not Ready for 15m.
- `FluentdDown` — the Fluentd aggregator not Ready for 15m.

Deliberately **not** alerting on cluster health `yellow`: a single-node Elasticsearch is permanently
yellow (decision 3), so that alert would fire forever and teach people to ignore the whole family —
the same reasoning already recorded for `VoteballJourneyTrafficStopped`.

**TLS split, settled during implementation.** Elasticsearch and Kibana ended up on opposite sides of
this decision, for opposite reasons. Elasticsearch keeps ECK's default self-signed HTTP TLS —
nothing outside the cluster ever talks to it, so a self-signed cert costs nothing, and Fluentd
verifies it properly (`ssl_verify true`) by mounting the CA ECK generates alongside the resource
(`voteball-logs-es-http-certs-public`), rather than disabling verification to make the connection
work. Kibana is the opposite case: it is the one component in this chart with a public route, and the
ALB in front of it already terminates real ACM TLS — the same shape `services/frontend` uses. Kibana
therefore sets `selfSignedCertificate.disabled: true` and serves plain HTTP behind the ALB. Leaving
ECK's self-signed cert on instead would put an HTTPS listener in front of the ALB's health check with
no CA it can validate — the same reason `services/frontend` runs plain nginx behind the ALB rather
than terminating TLS twice — so the target group would never go healthy and Kibana would be
unreachable even though the pod itself is fine.

### 10. Verification must count documents, not check pods

Three of this repo's most expensive defects share one shape: a check that passes against a component
that is healthy and doing nothing. Fluent Bit reporting Running while shipping nothing is precisely
that shape, and decision 5 makes it more likely by editing a config that replaces rather than merges.

So the acceptance test is **an end-to-end document count**: write a known line from a `devops-app` pod,
then query the Elasticsearch index for it and assert a non-zero hit. Per the repo's own rule, the check
is first exercised against input known to match, once, to prove it *can* pass — a `grep` that can never
match returns empty and reads identically to a correct negative.

## Component layout

| Piece | Location | Owner | Reaches cluster via |
|---|---|---|---|
| `eck-operator` 3.5.0 + 12 CRDs | `terraform/addon-eck.tf` | Terraform | `terraform apply` |
| `logging` namespace | `terraform/namespaces.tf` | Terraform | `terraform apply` |
| `Elasticsearch` CR | `charts/logging/templates/elasticsearch.yaml` | ArgoCD | `git push` → CD → `release` |
| `Kibana` CR + Ingress | `charts/logging/templates/kibana.yaml` | ArgoCD | same |
| Fluentd Deployment + ConfigMap + Service | `charts/logging/templates/fluentd.yaml` | ArgoCD | same |
| ILM policy + index template + write alias | `charts/logging/templates/ilm.yaml` | ArgoCD | same |
| NetworkPolicies (default-deny) | `charts/logging/templates/networkpolicy.yaml` | ArgoCD | same |
| Third Application + AppProject | `argocd/voteball-application.yaml.tmpl` | `render-argocd-app.sh` | `kubectl apply` at deploy step 11 |
| Fluent Bit second `[OUTPUT]` | `terraform/addon-cloudwatch.tf` | Terraform | `terraform apply` |
| `ElasticsearchDown` / `FluentdDown` | `charts/observability/templates/prometheusrule.yaml` | ArgoCD | `git push` |

`kubectl create namespace logging` is deliberately **not** used. Terraform owns namespaces here
(`terraform/namespaces.tf`); one created outside it is not deleted on destroy and can collide with the
next apply.

## Data flow

```
pod stdout (devops-app only)
  → /var/log/containers/*.log on the node
    → Fluent Bit DaemonSet  [tail + kubernetes metadata filter]   (unchanged, amazon-cloudwatch ns)
      ├─ [OUTPUT] cloudwatch_logs  → CloudWatch Logs   (unchanged; Grafana datasource)
      └─ [OUTPUT] forward          → Fluentd Service   (NEW, logging ns)
                                       ↓  buffer, retry, index routing, ILM alias
                                     Elasticsearch (1 node, 1 GiB heap, 20Gi gp3)
                                       ↑
                                     Kibana → ALB group `voteball` → kibana.<app_domain>
```

Network is default-deny in `logging`, mirroring `charts/observability`. Three flows are opened and
nothing else: Fluent Bit → Fluentd (ingest), Fluentd → Elasticsearch, Kibana ↔ Elasticsearch. The
namespace gets no egress to RDS and no egress to the AWS APIs — it needs neither.

## Testing

| Test | Kind | Where | Runs in CI? |
|---|---|---|---|
| Empty-list-literal sweep over `charts/*/templates` | offline, `grep` only | `scripts/ci/validate-repo.sh` | **yes** — it globs every chart, so `charts/logging` is covered automatically |
| Elasticsearch CR renders with `allow_mmap: false` and no privileged init container | offline | `scripts/tests/test-logging-chart.sh` | **no** — see below |
| The chart ships `enabled: true`, and `--set enabled=false` renders nothing | offline | same | **no** |
| The chart's share of the no-third-node budget | offline, arithmetic on rendered YAML | same | **no** |
| Teardown deletes CRs *before* the operator | offline, order assertion on `destroy.sh` | `scripts/tests/test-logging-teardown.sh` | **yes** — `grep` only, no helm |
| End-to-end document count (decision 10) | live cluster | `scripts/logging/verify-efk.sh`, deploy sub-step **11e**, after 11d | no (deploy-time) |

**`helm lint` and `helm template charts/logging` are run by NO automated check**, and the row above
that once claimed `scripts/ci/validate-repo.sh` does it was wrong: that script states in its own
comments that it is *"deliberately grep/awk only, no helm and no python3"*, because it runs in the CI
Validation stage before any tooling image is available. Its one relevant sweep — empty list literals
across `charts/*/templates` — does cover this chart, but it never renders it.
`scripts/tests/test-logging-chart.sh` is the file that renders the chart, and it sits in
`run-ci-suite.sh`'s **`SKIP`** list ("needs helm, absent from both agent containers"). So every
assertion it makes runs **only when a human invokes it**. See "Deliberately not done" for why that is
not closed here.

The new offline test joins `run-ci-suite.sh`. Its group must be decided by **running it in a bare
image**, not by reading it — the suite's `PYTHON_GROUP`/`GIT_GROUP`/`SKIP` lists are exhaustive and the
runner fails if a file appears in none, and build #7 established that guessing from the source text is
how tests land in the wrong container.

## Docs to update in the same change

- `docs/observability.md` — the two new alerts. **Enforced**: `scripts/tests/test-observability-docs.sh`
  fails the build if the alert set, counts, or one-runbook-per-alert drift.
- `docs/runbooks/README.md` — one runbook per new alert, both directions checked by that same test.
- `docs/deploy.md` — the new step, and the renumbering it causes.
- `docs/eks/architecture.md` — the diagram gains the `logging` namespace and the third ALB member.
- `README.submission.md` — EFK is a graded component; it needs its own section.
- `CLAUDE.md` — the new add-on, the teardown order, **and the stale "three releases" → four**.

## Deliberately not done

Recorded so a later pass does not "improve" these:

- **No replica shard, no second Elasticsearch node.** Yellow health is the designed state.
- **No `elasticsearch-exporter`.** Two kube-state-metrics alerts are the whole monitoring surface;
  a metrics exporter for a 1 GB index is more moving parts than the thing it watches.
- **No Filebeat**, though ECK ships the CRD. The brief says Fluentd.
- **No Logstash**, same reason.
- **No migration of `ci`/`argocd`/`monitoring` logs into Elasticsearch.** Those were ~95% of the
  original volume and were deliberately dropped in the 2026-08-03 cost pass; re-adding them here
  would quietly undo it and would not fit the sizing in decision 3.
- **No SSO for Kibana.** The built-in `elastic` user behind WAF is proportionate for a single-operator
  submission project.
- **`helm` is not added to a CI agent image, so `test-logging-chart.sh` stays in `run-ci-suite.sh`'s
  `SKIP` list.** This is a real, open gap: every chart-rendering assertion above — the privileged-init
  container check, `allow_mmap: false`, the shipped `enabled: true`, the budget arithmetic, the ALB
  group name — can be broken with every CI build staying green. Closing it means baking `helm` into an
  agent image (`ci/jenkins/`) and moving the test out of `SKIP`, which is an infrastructure change to
  the pipeline's own images, not a change to this feature; it is being surfaced to the repo owner
  separately rather than smuggled in here. `SKIP` already holds `test-jenkins-chart.sh` and
  `test-validate-observability.sh` for the same missing `helm`, so this adds no new *class* of hole —
  it makes the existing one wider by one chart.
