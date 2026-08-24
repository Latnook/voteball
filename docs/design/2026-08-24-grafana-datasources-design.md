# Grafana data sources: PostgreSQL, CloudWatch, GitHub

Adds three data sources to the Grafana that `kube-prometheus-stack` already runs, alongside the two
the chart provisions for itself (Prometheus, Alertmanager). Extends
`2026-08-17-observability-design.md` rather than replacing it: nothing there changes, and the
Terraform-vs-`git push` boundary that doc draws is what decides where each piece of this lands.

## Why

Grafana has two data sources today and both are chart defaults. That leaves two blind spots no
amount of PromQL reaches, and one class of question the metrics pipeline is not built to answer:

- **Inside RDS.** There is no `postgres_exporter` in this cluster, so nothing observes the database's
  CPU, connection count, free storage or IOPS. When `VoteballBackendErrors` fires at 3am, "is the
  database out of connections?" is currently unanswerable from Grafana.
- **At the ALB edge.** Prometheus scrapes pods. A request the load balancer rejected before it
  reached a pod is invisible to every panel on the site — including, by construction, the
  availability SLI.
- **Business facts.** How many votes arrived this week, which parties are trending, how the
  multi-league ballots distribute. These live in the eight rollup tables and are deliberately absent
  from Prometheus: they are unbounded-cardinality dimensions, and the brief bans exactly that.

Both AWS-side gaps are already being collected and already being paid for. Fluent Bit has been
shipping `devops-app` pod logs to CloudWatch since the add-on landed, and CloudWatch has been
recording RDS and ALB metrics for free the whole time. Neither has ever been readable next to the
metrics that would explain it.

## Decisions

### 1. Data sources ship as ConfigMaps on `git push`, not as Terraform values

The Grafana pod already runs a `grafana-sc-datasources` sidecar — verified live on the cluster:

```
container: grafana-sc-datasources
    LABEL       = grafana_datasource
    LABEL_VALUE = 1
    FOLDER      = /etc/grafana/provisioning/datasources
```

So a ConfigMap carrying `grafana_datasource: "1"` *is* a data source, with no API call and nothing
for a human to click. That is the same mechanism `charts/observability/templates/dashboards.yaml`
already uses for the three dashboards, and it keeps the property `docs/observability.md` §2 states
as fact: **there is no UI path**, because Grafana has no persistent storage and anything clicked into
it dies at the next Spot reclaim.

The rejected alternative was `grafana.additionalDataSources` in `helm_release.kube_prometheus_stack`.
One file, smallest diff — and every future data source change becomes a billed `terraform apply`
against live infrastructure. That inverts the boundary the whole repo draws: the platform arrives by
apply, the configuration on top of it by push. Dashboards already went the push way; a data source is
the same class of thing.

Terraform keeps only what is genuinely pod-spec-level and cannot be expressed in a ConfigMap: the
plugin list, the secret-to-environment projection, and the ServiceAccount's IRSA annotation.

### 2. CloudWatch authenticates by IRSA and holds no credential

Grafana's ServiceAccount carries no AWS role today. It gains one, following the pattern
`aws_iam_role.alertmanager` already established in this namespace.

This is the reason CloudWatch was chosen over the alternatives for the third data source: it is the
only one of the candidates that needs **no secret at all** — nothing to seed, rotate, leak or forget.
It is also core to Grafana rather than a plugin, so it depends on nothing downloadable at pod start
(decision 5).

The Logs half of the policy is resource-scoped to the three `/aws/containerinsights/voteball/*` log
groups. **The metrics half cannot be.** AWS publishes no IAM condition key for restricting
`cloudwatch:GetMetricData` or `ListMetrics` to a namespace, so those actions take `Resource: "*"`.
The grant is read-only and this is a single-purpose account, but the asymmetry is real and is
recorded in `docs/security.md` so a later reader does not mistake the wide half for an oversight.

Rejected: dropping metrics to keep every grant scoped. That would leave the data source duplicating
logs Fluent Bit already ships, discarding the RDS and ALB panels that were the entire reason
CloudWatch beat Loki and a `postgres_exporter`.

### 3. Grafana reads Postgres through a purpose-made role and a view, never the master user

`charts/voteball/values.yaml` sets `DB_USER: postgres` — the RDS **master** user. Pointing a
dashboard tool at that credential would give a query box unrestricted write access to production.

Instead a `grafana_ro` role, granted:

| Object | Grant |
|---|---|
| The 8 rollup tables | `SELECT` |
| `leagues`, `clubs`, `previous_parties`, `upcoming_parties` | `SELECT` |
| `v_grafana_votes` | `SELECT` |
| `votes`, `vote_clubs`, `vote_leagues`, `vote_upcoming_parties` | `REVOKE ALL` |

`votes` carries `cookie_token` (unique per voter) and `ip_hash`. Both are voter-linking identifiers,
so the base table is not readable. `v_grafana_votes` is a `CREATE OR REPLACE VIEW` exposing `id`,
`created_at`, `previous_vote_status`, `upcoming_vote_status` and `previous_party_id` — enough for
every time-series panel, and nothing that links a ballot to a person.

A view rather than column-level grants, for two reasons: a reviewer can read one object and know
exactly what Grafana can see, and `ALTER DEFAULT PRIVILEGES` — which is what stops a rollup table
added next month from becoming a broken panel next month — does not apply to column grants.

**The role is created without a password in `schema.sql`, and only `migrate.py` sets one.** This
split is not stylistic. `db.init_db()` runs `schema.sql` from three places — `migrate.py`, `app.py`'s
`__main__` guard and `gunicorn.conf.py`'s `on_starting` hook — so that file executes on **every
backend boot**, not only in the migrate Job. A `GRANT` naming a role that does not exist yet would
therefore fail every backend pod's startup, turning a monitoring feature into an application outage.
So `schema.sql` opens with an idempotent guarded `CREATE ROLE grafana_ro LOGIN` (no password) before
the view and the grants, and a backend pod never needs `GRAFANA_DB_PASSWORD` to start. A Postgres
role with no password cannot authenticate under `scram-sha-256`, so the intermediate state fails
closed rather than open.

### 4. The role is created by the migrate Job, so there is no manual step and no drift

RDS sits in isolated subnets with no NAT route. A laptop cannot reach it; the removal of
`scripts/sync-seed-from-rds.sh` on 2026-07-20 was exactly this problem, and porting it would mean a
`kubectl port-forward` through a backend pod.

`voteball-migrate` already runs in-cluster on every release, already holds the master credential and
already reaches RDS, so it is where the password is set: `migrate.py` reads `GRAFANA_DB_PASSWORD`
from the environment and issues a single idempotent `ALTER ROLE grafana_ro PASSWORD ...` after
`init_db()` returns. The role, view and grants themselves live in `schema.sql` per decision 3; only
the interpolated secret needs Python, because `schema.sql` is a static file with nowhere to put one.
Two consequences worth stating:

- **No new manual operation.** The rubric requires manual operations be documented; the best outcome
  is not having one.
- **The role and the secret cannot drift.** The Job sets the password from the same Secrets Manager
  value ESO projects into Grafana, every release. A rotation is picked up automatically on the next
  sync rather than silently leaving the data source authenticating with a stale password.

### 5. GitHub is the one fragile data source, and nothing important rests on it

**Three of the four data sources need no plugin at all.** Verified against the running container
(`grafana/grafana:13.1.1`) rather than inferred from the names — every one of these is compiled into
the binary at `/usr/share/grafana/public/app/plugins/datasource/`:

```
alertmanager  azuremonitor  cloud-monitoring  cloudwatch  dashboard  grafana
grafana-postgresql-datasource  grafana-pyroscope-datasource
grafana-testdata-datasource  graphite  influxdb  jaeger  loki  mixed
mssql  mysql  opentsdb  parca  prometheus  tempo
```

So `prometheus`, `cloudwatch` and `grafana-postgresql-datasource` are a provisioning file and nothing
else. Only `grafana-github-datasource` is fetched.

**The distinction that governs reliability here is image-resident vs network-fetched, not core vs
plugin.** `/var/lib/grafana` is an `emptyDir`, yet it holds `elasticsearch`, `zipkin` and four
`*-app` plugins, all timestamped at pod start: Grafana 13 bakes a second tier of plugins into the
image and its entrypoint copies them into the volume on every boot. Those are as reliable as the
compiled-in ones despite sitting on ephemeral storage, because they are never downloaded.

A `GF_INSTALL_PLUGINS` entry is different in kind. It downloads into that same `emptyDir`, which is
wiped and repopulated from the image at every pod start — the image copy restores what it carries,
and the downloaded plugin is simply gone. So the GitHub plugin is **re-fetched from grafana.com on
every pod start**, which on a 100% Spot node group is roughly daily. If grafana.com is unreachable
that morning, Grafana comes up healthy and the GitHub panels are simply absent, with the reason in
container logs nobody is reading.

There is no clean fix that does not undo decision 1. The mitigation is placement: the two data
sources carrying real operational weight (Postgres, CloudWatch) are both **core**, compiled into the
Grafana binary, and depend on nothing downloadable. GitHub is allowed to be the fragile one precisely
because no alert, no SLI and no incident path depends on it.

**No pull-request panels.** `Latnook/voteball` is a solo repo committed straight to `master`; a PR
panel would be a permanently-empty box. The panels are commit activity, contributors and open issues,
appended to the existing `jenkins-delivery.json` so commit volume sits next to the builds it caused.

Token: a **fine-grained** PAT scoped to `Latnook/voteball` alone, read-only on Contents, Metadata and
Issues. Rejected `public_repo` on a classic PAT — it grants *write* to every public repo on the
account, which is the wrong trade for a credential parked in a monitoring stack. The cost is that
GitHub enforces an expiry (one year maximum), so the panels break on a forgotten date; the expiry
goes in `docs/maintenance.md` next to the EKS standard-support deadline, which is the only other
date-bomb this repo tracks.

### 6. Secrets: one container, two projections

A single Secrets Manager secret `voteball/grafana` holding `db_password` and `github_token`,
projected by **two** ExternalSecrets:

- into `observability` — both keys, reaching Grafana as environment variables that the provisioning
  files interpolate;
- into `devops-app` — `db_password` only, for the migrate Job's `ALTER ROLE`.

The GitHub token therefore never enters the application namespace. Terraform creates the empty
container with `ignore_changes = [secret_string]`, exactly as `voteball/app-secret` and
`voteball/jenkins` already do, so no secret value enters git or tfstate.

### 7. NetworkPolicy does not change

Checked rather than assumed. `charts/observability/templates/networkpolicy.yaml`'s
`allow-observability-egress` already permits:

- `10.0.0.0/16` (the scrape-targets rule) — which covers RDS in the isolated subnets;
- `0.0.0.0/0` minus RFC1918 (the AWS rule) — which covers the CloudWatch and STS endpoints,
  grafana.com for the plugin download, and api.github.com.

That file's own comment warns that its egress list is the half that fails silently. It needs no edit
here, and this section exists so that fact is recorded rather than rediscovered.

### 8. Dashboard refresh intervals are pinned, because they are billed

CloudWatch metrics bill per metric returned. The `aws-infrastructure` dashboard requests roughly 10
metrics per refresh (6 RDS + 4 ALB):

| Refresh | Metrics/day | Cost/month |
|---|---|---|
| 5 minutes (shipped) | ~2,900 | ≈ $0.04 |
| 10 seconds (Grafana's default) | ~86,000 | ≈ $8.60 |

So the refresh is set explicitly in the dashboard JSON with a comment saying why, rather than
inherited. CloudWatch **Logs Insights** bills per GB *scanned*, not stored, so an auto-refreshing log
panel re-scans its whole window forever: logs are an on-demand Explore path plus one short-default-
range panel, never a refreshing one. This is the same trap that made `containerInsights` and
`applicationSignals` cost $3.00/day before they were cut (`terraform/addon-cloudwatch.tf`), wearing a
different hat.

### 9. What deliberately does not change

- **kube-prometheus-stack's own two data sources.** Prometheus and Alertmanager stay chart-managed.
  Re-declaring them in `charts/observability` would create a second source of truth for something
  already correct.
- **Grafana still has no PVC and no public Ingress.** Reached by `kubectl port-forward`, password
  generated fresh at install.
- **No `postgres_exporter`.** RDS internals come from CloudWatch, which already collects them at no
  additional cost. An exporter would be a second collection path for the same numbers, plus a pod.
- **No Loki.** A StatefulSet, an S3 bucket and more node RAM on a cluster already at ≈$8.50/day, to
  duplicate a CloudWatch log pipeline that is already running and already trimmed to `devops-app`.

## The four silent failures

Every one of these leaves Grafana healthy, green and wrong. Listed because that is the failure class
this repo keeps finding the expensive way.

1. **ESO's IAM policy is an explicit ARN allowlist.** `terraform/addon-eso.tf` names
   `aws_secretsmanager_secret.app` and `.jenkins` and nothing else. Omit the new entry and the
   ExternalSecret fails while Grafana boots normally with an empty password — discovered when a panel
   loads, not at deploy time.
2. **An environment-variable name typo expands to an empty string.** Grafana's provisioning
   interpolation does not error on an unset variable. Identical symptom to (1), different cause.
   `scripts/tests/test-grafana-datasources.sh` cross-checks every `$VAR` in the data source
   ConfigMaps against what Terraform actually projects — offline, no cluster.
3. **Plugin download failure at pod start** leaves Grafana healthy and the GitHub data source absent.
   Accepted, per decision 5.
4. **A new rollup table with no grant** breaks a panel weeks after the commit that caused it.
   `ALTER DEFAULT PRIVILEGES` is what prevents it, and is the reason it is in decision 3.

## Documentation the change forces

`scripts/tests/test-observability-docs.sh` fails the build when the charts drift from the docs, and
this change trips three of its checks by design: the dashboard count (3 → 5), each new dashboard's
`uid`, and each dashboard's panel count — including `jenkins-delivery`, whose count moves when the
GitHub panels are appended. `docs/observability.md` gains a data source section and must be updated
in the same commit. `docs/security.md` gains the `grafana_ro` grant table and the CloudWatch metrics
scope note from decision 2.

## Verification outcome

### The sequencing defect: a consumer shipped without its producer

**Found live on 2026-08-24, during implementation, at the cost of two production rollbacks.**

Decision 6 puts the Secrets Manager container in Terraform and the ExternalSecrets that read it in
the Helm charts. That split is correct — it is the same platform-vs-configuration boundary the whole
repo draws. What the design failed to state is that **the two halves travel at different speeds**:

| Half | Lives in | Reaches the cluster by | Latency |
|---|---|---|---|
| The secret container | `terraform/secrets.tf` | a billed `terraform apply` | whenever a human runs it |
| The ExternalSecrets | `charts/{voteball,observability}` | a `git push` → CI → CD → ArgoCD | minutes, automatically |

So committing the chart half put a consumer in the cluster while its producer did not yet exist.
`voteball/grafana` was not in Secrets Manager — the account held exactly two secrets, `voteball/app-secret`
and `voteball/jenkins` — and the failure cascaded further than a missing dashboard credential should:

```
kubectl get externalsecret -n devops-app     grafana-db-secret    SecretSyncedError  False
kubectl get externalsecret -n observability  grafana-datasources  SecretSyncedError  False
kubectl get application -n argocd            voteball       Synced/Degraded  op=Failed
                                             observability  Synced/Degraded
```

ESO cannot resolve the reference, so the resource is Degraded, so ArgoCD's **whole sync operation**
reports `phase: Failed` — and because anything failing after `application-cd`'s Promote stage
triggers an automatic rollback, every CD run became *deploy fails → roll production back*. It ran
twice (`application-cd` #4 and #6, both rolling back to `2356172`) before anyone noticed, while
`master` moved several commits ahead of what was actually serving. A monitoring feature that had not
been switched on yet was reverting unrelated application fixes.

**The fix is a gate, defaulting off**: `.Values.externalSecret.grafanaEnabled` in `charts/voteball`
and `.Values.externalSecret.enabled` in `charts/observability`, both `false` until `terraform apply`
has created the container *and* `scripts/seed-grafana-secret.sh` has seeded it.

### The general rule this produces

**Any chart resource that references a Terraform-created object must be gated off by default.** The
gate is not defensive style; it is what keeps the two deployment speeds from being a race. The repo
already had this shape and it was not recognised in time: `charts/voteball`'s own `app-secret`
ExternalSecret reads a container Terraform creates empty and `seed-eks-secret.sh` fills — the same
pattern, which had simply always been seeded before anyone looked.

### A third finding: enabling the gates is not enough — Grafana must be restarted

**Observed on the enabling deploy, 2026-08-24, and mis-diagnosed twice before being found.**

Flipping the two gates to `true` and pushing does not make the PostgreSQL data source work. The first
panel load fails with:

```
db query error: failed to connect to `user=grafana_ro database=postgres`:
failed SASL auth: FATAL: password authentication failed for user "grafana_ro" (SQLSTATE 28P01)
```

The cause is not ArgoCD hook ordering, which is what it looks like and what this document claimed for
an hour. It is **environment-variable projection**, and the evidence is a pair of timestamps:

```
Grafana pod started ................. 18:58:13Z
grafana-datasources Secret created .. 19:19:09Z   (21 minutes later)
GF_DATASOURCE_DB_PASSWORD in the running container .. NOT SET
```

`envFromSecret` projects a Secret's keys as environment variables **at pod start and never again**.
The Grafana pod predated its Secret by 21 minutes, so the variable was never set — and Grafana
expands an unset variable in a provisioning file to an **empty string** rather than erroring
(silent failure #2 in this document). So Grafana authenticated with an empty password.

**The fix is one command, not a second sync:**

```bash
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
```

**This repo already documented this exact trap, for Jenkins**, in the root `CLAUDE.md`: *"`--restart`
covers a new key in `voteball/jenkins`, which `containerEnvFrom` projects only at pod start."* Same
mechanism, adjacent component, and it was walked into anyway — which is the more useful half of the
finding. A rule written for one component does not generalise itself to its neighbour.

### A fourth finding: a CloudWatch panel can be correct on the server and blank in the browser

Every panel on `voteball-aws` returned real data from `/api/ds/query` — 66 points on RDS CPU — while
the dashboard rendered "No data" in the browser, with no error anywhere.

The ten metric targets lacked `queryMode`, `metricQueryType` and `metricEditorMode`. The backend
fills defaults for those; the **frontend** dispatches on them to choose a query builder, takes the
other branch when they are absent, and sends an empty query.

This is the worst verification gap in the whole feature, because **every check built for it went
through the backend** — the per-panel query sweep, `validate-observability.sh`, the data source health
probes. All reported green against a blank dashboard. The two consumers of the same stored JSON
disagree about what a valid query is, and only one of them was ever exercised.

It was found by a human noticing that Business Analytics worked from the same Grafana while these did
not — one observation that eliminated the credential, the data source and the backend at once. No
automated check in this repo would have caught it.

### A fifth finding: gating the chart resources was not enough — a fresh deploy still needed to seed, split and restart

**Found ahead of an actual billed rebuild, before it happened rather than during it, 2026-08-24.**

The first three findings above fixed a *live* cluster that already had a real `db_password` sitting in
`voteball/grafana` and a Grafana pod a human had already restarted by hand. None of that survives
`destroy.sh` → `deploy.sh`: Terraform recreates `voteball/grafana` holding only its placeholder, and
both chart gates (`charts/voteball`'s `externalSecret.grafanaEnabled`, `charts/observability`'s
`externalSecret.enabled`) are committed **true** — so a fresh deploy would reproduce the exact
2026-08-24 outage from scratch, on the very first sync. Three fixes, made together because each one
alone would have left a gap the other closed:

1. **`scripts/deploy.sh` now seeds `voteball/grafana` itself**, at a new step 3c (between the Jenkins
   secret and the GitHub deploy-key registration, which moved from 3c to 3d), before the billed apply
   — the same shape as steps 3/3b for the app and Jenkins secrets. `scripts/seed-grafana-secret.sh`'s
   own idempotency guard makes this safe to re-run.
2. **`GITHUB_TOKEN` had to become genuinely optional**, not just undocumented. An unattended
   `deploy.sh` run has no human to prompt, and the token guards nothing load-bearing (decision 5) — so
   it must never block or fail the seeding step. `seed-grafana-secret.sh` now uses it if supplied,
   offers an optional prompt only when a terminal is attached, and otherwise seeds `db_password`
   alone — carrying forward whatever `github_token` a rotation left in place rather than silently
   deleting it (`put-secret-value` replaces the whole `SecretString`, so omitting the key is
   destructive, not neutral).
3. **The single two-key `grafana-datasources` ExternalSecret was the wrong shape once the token
   became optional.** ESO fails an ExternalSecret's *entire* sync if any one `data` entry is
   unresolvable, so a deploy with no token (now the common, unattended case) would have taken the
   PostgreSQL data source down with it — reproducing the original outage through a different door.
   `charts/observability/templates/externalsecret.yaml` now declares two independent ExternalSecrets
   (`grafana-datasource-db` → Secret `grafana-datasources`, `grafana-datasource-github` → Secret
   `grafana-datasources-github`), gated independently (`dbEnabled`/`githubEnabled`), each projected
   into Grafana via its own entry in `terraform/addon-monitoring.tf`'s `grafana.envFromSecrets` list
   (both `optional = true`).

**Restarting Grafana (finding 3, above) also had no automated caller.** `scripts/deploy.sh` step 11d
now runs `scripts/restart-grafana-datasources.sh` after ArgoCD's sync (step 11) — conditional on the
Secret actually existing and not already projected, so a routine re-run does not churn a healthy pod,
and non-fatal, so a Grafana hiccup never fails a deploy whose application is otherwise up.
`scripts/tests/test-restart-grafana-datasources.sh` and an extended
`scripts/tests/test-grafana-datasources.sh` (checking the split ExternalSecrets and the per-entry
`optional = true`) cover all of this offline.

### A second finding: "holding pushes" is meaningless on a shared branch

These commits reached `origin/master` without this session ever running `git push`. A concurrent
session pushed *its* commit, which sat on top of mine, and git pushes the entire ancestor chain. Any
agreement to hold pushes on a shared branch is therefore unenforceable by the party holding — it
only takes effect if every other writer also holds. The isolation that would actually deliver it is
a branch or a worktree, which this plan explicitly ruled out for unrelated reasons (the gitignored
`terraform/backend.hcl` exists only in the main tree).
