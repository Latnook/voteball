# charts/logging — CLAUDE.md (EFK: Elasticsearch, Fluentd, Kibana on the ECK operator)

*Moved verbatim from the root `CLAUDE.md` on 2026-10-02 so it loads only when working here. Where a paragraph says "above" or "below" about something not in this file, it is in one of: `terraform/CLAUDE.md`, `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`, `charts/observability/CLAUDE.md`, `charts/voteball/CLAUDE.md`, or the `voteball-cicd` skill.*

**ECK operator (`terraform/addon-eck.tf`) — the ECK add-on, added for EFK logging.** Terraform-owned
like ArgoCD itself, and for the identical reason: its chart installs 17 cluster-scoped objects (12
CRDs, 3 `ClusterRole`s, 1 `ClusterRoleBinding`, 1 `ValidatingWebhookConfiguration`), and every
AppProject's `clusterResourceWhitelist: []` makes ArgoCD structurally unable to manage them. Installs
into `elastic-system`; `managedNamespaces` is scoped to `logging` alone so it never reconciles a
custom resource anywhere else in the cluster. The namespaced objects it reconciles — `Elasticsearch`,
`Kibana`, `Fluentd` — live in **Helm (`charts/logging`)**, delivered by its own third ArgoCD
Application/AppProject the same way `charts/observability` is.

**That chart also ships Kibana's CONTENT, and it is not decoration.** `charts/logging/kibana/*.json`
holds the `voteball-logs` data view, three saved searches and the `Voteball service health`
dashboard, imported by a `post-install,post-upgrade` hook (weight 10, strictly after the ILM
bootstrap's 5). Without them the stack passes every check and is unusable -- measured 2026-09-07,
before they existed: 59,926 documents indexed, 223 Kibana saved objects, **every one an Elastic
built-in**, so anyone opening `kibana.<app_domain>` got an onboarding screen and could not see a log
line without clicking through setup first. Two traps, both proven against the live Kibana 9.1.4
rather than read from docs: a saved object with no **`typeMigrationVersion`** makes
`/api/saved_objects/_import` run the entire migration chain and answer **HTTP 500** with the reason
only in the Kibana server log; and `_import` answers **200 for an import that saved nothing** (the
per-object failures come back in the *body*), so the Job compares `successCount` against the object
count and then reads the dashboard back through a *different* call -- a dangling panel reference
imports cleanly and renders as an error card. The matching half is the log line itself:
**`templates/fluentd.yaml` parses it** into `http_status`/`http_path`/`log_level`, and
`reserve_data true` plus the trailing `format none` catch-all are what stop `filter_parser` from
silently DROPPING every record matching no pattern (the worker's entire output matches none).
**A fresh install DEADLOCKS without `action.auto_create_index` on the Elasticsearch CR, and the
deadlock is invisible because everything else stays green.** The bootstrap Job is a `post-install`
hook, which ArgoCD maps to **PostSync** — so it runs *after* the Fluentd Deployment and Fluentd
wins the race. Fluentd's first write auto-creates a plain INDEX named `voteball-logs` carrying the
DEFAULT one replica (the `number_of_replicas: 0` template matches `voteball-logs-*`, **not** the
bare name), one unassigned replica turns a single-node cluster YELLOW, and ArgoCD then blocks on
`waiting for healthy state of .../Elasticsearch/voteball-logs` — so PostSync never fires, so the
Job **whose own code deletes that squatting index** never runs. The Job has handled the squatter
since 2026-08-28; nobody noticed its fix was locked behind the condition it fixes. Measured on the
2026-09-08 rebuild: 136 documents, 1 unassigned shard, `logging` stuck Synced/**Progressing**
indefinitely while `voteball` and `observability` were Healthy, the site served 200 throughout, and
`deploy.sh` exited 0 — it treats EFK verification as a WARNING on purpose, since CloudWatch keeps
the authoritative copy. `action.auto_create_index: "-voteball-logs,+*"` refuses the squatter, so
Fluentd's early writes are retried instead of poisoning the health signal. Verified live that the
guard does **not** block writes through the alias once it exists (HTTP 201, routed to
`voteball-logs-000001`) — it governs auto-creation only, and `+*` must stay last.

**That config reaches the running pod ONLY because of the `checksum/config` pod annotation.** A
ConfigMap change restarts nothing, and this one is mounted with `subPath`, which kubelet never
refreshes -- so without the annotation a new `fluent.conf` lands in the cluster, ArgoCD reports
Synced/Healthy, `application-cd` reports success, and Fluentd runs the old config until something
unrelated reschedules the pod. Hit for real the day the parser shipped: both PostSync hooks
Succeeded, every check green, and `grep -c multi_format /fluentd/etc/fluent.conf` in the running
pod returned 0 against a pod 24 hours old. `verify-efk.sh` does not catch it either -- an unparsed
document still counts. It
also drops `ELB-HealthChecker` lines, which were **37.2% of the index**, from Elasticsearch only --
CloudWatch is upstream of the fan-out and keeps the authoritative copy. See
`docs/design/2026-08-27-efk-logging-design.md` decisions 11 and 12.

**That chart ships `enabled: true`,
and nothing anywhere flips it** — the deploy *ordering* is what makes it safe, the same shape as the
Grafana gates ("the gates ship `true` because the seed step makes that safe"): the CRDs arrive with
`terraform apply` at step 6 and the `logging` Application is not created until step 11, so a git
push can never land the consumer ahead of its dependency. Deploy **step 11e verifies** the pipeline
end to end (`scripts/logging/verify-efk.sh`); it does not enable it. Shipping `enabled: false` here
would be the 2026-08-25 corollary with no second half: zero objects rendered, ArgoCD Synced/Healthy
on an empty manifest, deploy reports success. **Teardown order is the reverse of install, and
specifically the opposite of what you'd guess**: `destroy.sh` deletes the `Elasticsearch`/`Kibana`
custom resources first, then `helm uninstall`s the `logging` release, and only then the operator
itself — because **ECK attaches finalizers** to those custom resources and to the Secrets they own,
and only the running operator clears them. Remove the operator first and every CR sits `Terminating`
with no controller left, the same hang `kubernetes_namespace.ci` produced on 2026-08-04. It is **not**
the `ValidatingWebhookConfiguration` — all 16 of its webhooks are `failurePolicy: Ignore` on
`operations: [CREATE, UPDATE]`, so a DELETE is never intercepted and an unreachable webhook is
skipped rather than blocking (verified by rendering `eck-operator` 3.5.0). The order is right; that
explanation was not, and it stood in four places at once. See
`docs/design/2026-08-27-efk-logging-design.md`.

**Deleting the two custom resources is NOT enough — the `logging` NAMESPACE has to be deleted in
that same window, while the operator still lives.** ECK finalizes the Secrets its resources own as
well as the resources themselves, so once `helm uninstall elastic-operator` has run there is no
controller left to clear them, and Terraform reaches `kubernetes_namespace_v1.logging` minutes later
to find it un-deletable. Measured on the 2026-09-07 teardown — the first full destroy since the EFK
pass added this namespace — it was still `Still destroying... 01m40s elapsed` when the run failed,
and only the automatic state-rm retry got the teardown home, at the cost of a second full
`terraform destroy`. `destroy.sh` step 4 therefore runs
`kubectl delete namespace logging --timeout=180s` between `helm uninstall logging` and
`helm uninstall elastic-operator`, **and it waits.** The first version used `--wait=false`, on the
reasoning that the namespace only had to be *asked* to go while the operator was alive. The
2026-09-08 10:19 teardown disproved that in its own log: `namespace "logging" deleted` printed,
then `release "elastic-operator" uninstalled` on the very next line, and Terraform still found the
namespace Terminating minutes later. **A delete is accepted instantly and finalizers are cleared
afterwards, so the operator has to survive the whole finalization, not just the request.**
