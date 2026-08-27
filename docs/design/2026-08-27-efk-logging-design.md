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

| Component | Placement | Requests | Limits |
|---|---|---|---|
| `eck-operator` | either node | 100m / 150Mi | 1 / 1Gi (chart default) |
| `Elasticsearch` (1 node, 1 GiB heap) | pinned to 1a by its EBS volume | 300m / 2Gi | 1 / 2Gi |
| `Kibana` | 1b, anti-affinity from Elasticsearch | 200m / 1Gi | 500m / 1Gi |
| `Fluentd` aggregator | 1b | 100m / 256Mi | 500m / 512Mi |

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

**Reversed, it hangs.** The `ValidatingWebhookConfiguration` intercepts writes to
`*.k8s.elastic.co` objects; with the operator already gone there is no backend to answer, so every CR
delete blocks. That is the same class as the `kubernetes_namespace.ci` finalizer hang of 2026-08-04 —
no controller left alive to clear its children.

ECK's `volumeClaimDeletePolicy` defaults to deleting the PVC when the Elasticsearch resource is
deleted, so the Elasticsearch volume needs no equivalent of the step-5 observability-PVC cleanup. This
is asserted by the teardown test rather than assumed.

### 8. Gating and deploy ordering

`charts/logging` ships **`enabled: false`**, and `scripts/deploy.sh` flips it after the billed apply.

The rule this follows is already written down: a chart resource that references a Terraform-created
object must be gated off, because chart code reaches the cluster on a `git push` (minutes, automatic)
while the object it names arrives only on an apply a human runs. Here the `Elasticsearch`/`Kibana` CRs
reference CRDs that only `terraform apply` installs. Pushing the consumer first is the 2026-08-24
outage exactly — ESO could not resolve a reference, the resource went Degraded, the whole ArgoCD sync
reported `phase: Failed`, and four consecutive CD runs rolled production back.

The corollary from 2026-08-25 applies too: **a gate that is off in git is a rebuild that does not
work**, so the enable step ships in the same change as the gate, not as follow-up. Because the CRDs
arrive in the same apply that creates everything else (step 6) and the ArgoCD Applications are created
at step 11, the ordering holds naturally on a fresh deploy.

### 9. Exposure, access control and alerting

**Kibana** is published as `kibana.<app_domain>` on the existing ALB group `voteball`. A grouped ALB
de-provisions only when *no* member Ingress remains, so this becomes the **third** member alongside
`devops-app/voteball` and `ci/jenkins-webhook`, and `scripts/cleanup-stale-dns.sh` gains a third host
(`HOSTS` currently lists two).

Authentication is **ECK's built-in `elastic` user**, whose password the operator generates into a
Kubernetes Secret. No second auth system, no ExternalSecret, nothing new in Secrets Manager. The WAF
ACL already attached to the ALB covers it. TLS is ACM at the ALB, as for every other host.

**Alerting** adds two rules to `charts/observability`, both built on kube-state-metrics — no new
exporter:

- `ElasticsearchDown` — the Elasticsearch pod not Ready for 15m.
- `FluentdDown` — the Fluentd aggregator not Ready for 15m.

Deliberately **not** alerting on cluster health `yellow`: a single-node Elasticsearch is permanently
yellow (decision 3), so that alert would fire forever and teach people to ignore the whole family —
the same reasoning already recorded for `VoteballJourneyTrafficStopped`.

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

| Test | Kind | Where |
|---|---|---|
| `helm lint` / `helm template charts/logging` | offline | `scripts/ci/validate-repo.sh` (existing sweep) |
| Elasticsearch CR renders with `allow_mmap: false` and no privileged init container | offline | new `scripts/tests/test-logging-chart.sh` |
| Requests sum leaves ≥3 GiB free per node (the no-third-node budget) | offline, arithmetic on rendered YAML | same |
| Teardown deletes CRs *before* the operator | offline, order assertion on `destroy.sh` | same |
| End-to-end document count (decision 10) | live cluster | `scripts/logging/verify-efk.sh`, new deploy sub-step **11e**, after 11d |

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
