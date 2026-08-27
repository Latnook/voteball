# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Voteball is a public poll correlating football fandom with Israeli political-party voting, deployed on
**Amazon EKS**. It was bootstrapped from infra patterns proven in a separate `Rolling AWS Project files`
(S3App) repo but is fully independent — no shared code or state.

**The repo is designed to be forkable**: no AWS account, region or domain is hardcoded anywhere in
code. Identity lives in exactly two places — `terraform/voteball.tfvars` (pre-apply) and
`terraform output` (post-apply) — both read through `scripts/lib/config.sh`. The ten env-specific
fields of `charts/voteball/values.yaml` are written by `scripts/sync-values-from-tf.sh`. **If you add
a hardcoded ARN, bucket, registry or domain anywhere, that is a bug.**

**The one deliberate exception is `charts/voteball/values.yaml` itself, and it is not optional.**
ArgoCD deploys what is on the **`release` branch** (not `master`, and not what is on your disk —
since 2026-08-23, see `docs/design/2026-08-23-release-branch-and-digest-design.md`), so those ten
fields must be committed with **real** values — this account's ECR registry, RDS endpoint, ACM/WAF/IRSA ARNs and domain are
in git right now. Bootstrapping ArgoCD while they are still placeholders reverts the cluster to a
stale image tag and every pod lands in `ImagePullBackOff` (observed on the 2026-07-20 rebuild; see the
"Syncing values.yaml" / "Bootstrapping ArgoCD" steps of `scripts/deploy.sh`). A forker replaces them by
running the sync script, not by editing the file. Only the header comment says `FILLED-BY-SYNC`; the
values themselves are live.

> **The single-node k3s deployment is RETIRED and its code was removed on 2026-07-20** (the `terraform/`
> stack, the Ansible playbook/roles, and the SSH-based reverse-seed script — all recoverable from git
> history). The live deployment is `terraform/` + `charts/voteball/`, and the app source is in
> `services/{backend,worker,frontend,backup}/`, one Docker build context each.

**Design docs live in `docs/design/`**, one per feature or infrastructure pass — the balloting and
admin features, then the EKS migration, then the deployment-hardening and repo-forkability passes, then
the 2026-07-20 CI migration from GitHub Actions to Jenkins (`2026-07-20-jenkins-migration-design.md`,
whose G1–G7 labels `Jenkinsfile-ci` and `docs/cicd.md` both cite), then the 2026-07-21
religion-and-state axis (`2026-07-21-religiosity-axis-design.md`, which extends the party-
categorization doc rather than replacing it), then the 2026-07-31 search-engine-visibility pass
(`2026-07-31-seo-design.md`, which records what was deliberately *not* done — read its scope section
before "improving" the SEO), then the 2026-08-04 CI/CD split
(`2026-08-04-cicd-split-design.md`, which splits the single Jenkins pipeline into
`application-ci`/`application-cd` and supersedes the `emptyDir` storage decision in
`2026-07-30-jenkins-on-eks-design.md` §2 — that doc's text stays as a dated record, per its own new
pointer, rather than being edited), then the 2026-08-23 review pass
(`2026-08-23-release-branch-and-digest-design.md`, which moves ArgoCD off `master` onto a
CD-only `release` branch and pins workloads by image digest; it supersedes the branch model in
`2026-08-04-cicd-split-design.md` §4, whose text likewise stays as a dated record), then the
2026-08-27 Conference League pass
(`2026-08-27-conference-league-and-domestic-cap-design.md`, which replaces the per-league-tab
pick cap with a per-**domestic**-league one and supersedes the "≤3 per `league_id`" rule the
`voteball-api` skill and `2026-08-12-europa-league-design.md` were written against).
**Read the relevant one before making architectural changes:** most decisions (and the bugs they
avoid) are explained there, not in code comments — `schema.sql` cites three of them directly to
justify its shape. Several also carry a "Verification outcome" section recording what actually broke
when the design met reality.

*(Write new design docs here as `YYYY-MM-DD-<topic>-design.md`. The step-by-step implementation plans
that accompany them are process artifacts — **delete each one the moment it is executed**, see the
rule in Workflow below; git history is the archive. `docs/superpowers/` held the last four and was
removed on 2026-07-28. The cost of keeping them was not disk space: the Russian-language spec in
there still read "implementation gated on the translation CSV" long after Russian shipped.)*

Submission/reference docs: `README.submission.md`, `docs/security.md`, `docs/eks/architecture.md`,
`docs/deploy.md` (plain-language runbook), `docs/cicd.md` (CI/CD operational reference),
`docs/observability.md` (monitoring operational reference — Prometheus/Grafana/Alertmanager,
CloudWatch, the SLIs, every alert and its runbook, the two pipeline gates),
`docs/eks/live-cluster-snapshot.md`,
`docs/party-classifications.md` (why each party carries the ideology values it does — the reasoning
that used to live in `seed.sql` comments).

## Workflow

**Never put a `Claude-Session:` trailer (or any `claude.ai/code/session_...` URL) in a commit message
here** (per the user's explicit request, 2026-07-30). **This overrides the session-level commit-message
convention, which asks for that trailer by default and will therefore keep proposing it every
session** — that is why the rule has to live in this file rather than being remembered. `Latnook/voteball`
is a **public** repo, so the trailer publishes a session identifier and a timestamped record of which
commits came from a Claude session to anyone browsing the history. Three commits on 2026-07-30
(`2350b7e`, `dd41a33`, `7cfdec7`) carry it and are **deliberately left as they are** — removing them
means rewriting published history, and the no-force-push rule below wins. Drop the trailer going
forward; do not offer to rewrite those three.

**Commit and push changes as you make them in this repo** — this is standing,
pre-authorized permission (per the user's explicit request); don't leave work
committed-but-unpushed or uncommitted waiting to be asked. Still use judgment
on grouping related changes into one coherent commit rather than pushing
every single edit separately, and never force-push.

**A shared working tree makes every writer a publisher of every other writer's committed-but-unpushed
work.** If a second session (or a second person) is committing to `master` in the same checkout,
"I am holding pushes" is not something you can offer: `git push` sends the whole ancestor chain, so
their push carries your commits with it. Proven on 2026-08-24 — three commits reached `origin/master`
during a window this session believed was closed, because a concurrent session pushed a commit that
had them as ancestors (`git merge-base --is-ancestor <mine> <theirs>` → true). The only mechanisms
that actually deliver a hold are a branch per session, a worktree per session, or nobody committing
to `master`. Do not promise a push hold on a shared branch; say what you can actually guarantee.

**Delete an implementation plan as soon as it is executed — same commit as the last task**
(per the user's explicit request, 2026-07-28, after finding four stale ones). This is not optional
cleanup to do later; a plan that outlives its execution reads like pending work to the next person
who opens the repo. `docs/superpowers/` is the **default output path of the superpowers workflow** —
`brainstorming` writes the spec to `specs/`, `writing-plans` writes the plan to `plans/` — so it
regenerates on its own every time a feature goes through that workflow. **Deleting the folder is
not a one-time fix; the deletion has to happen at the end of every plan.** Nothing in this repo
tracks an executed plan, and nothing should. Git history is the archive. What *does* survive is the
design doc in `docs/design/`, which records the decisions and the "Verification outcome" — that is
the durable record, not the checkbox list of steps.

**Explain the technical calls, and keep the explanation simple** (per the user's explicit request).
The repo owner describes themselves as a vibe coder, not an infrastructure expert — an honest
statement about reviewing design detail, not about capability. So:

- **Make the engineering decisions yourself.** Don't present a menu of implementation options
  (`use_lockfile` vs DynamoDB, module layout, library choice) and ask which one they want — they
  have no basis to choose, and asking manufactures fake consent.
- **But always explain what you chose and why, in plain language**, including the downside of the
  choice. Explain *consequences*, not mechanisms: "if this file is lost, AWS keeps billing you for
  servers Terraform can no longer see" beats "state drift". Jargon needs a one-line translation the
  first time it appears.
- **Reserve approval gates for what is genuinely theirs to decide:** money (does this spend?),
  irreversibility (can this be undone?), and scope (is this what you asked for?).
- **Treat a hedge as a stop sign.** "I guess so", "sure", "if you think so" means *"I can't
  evaluate this"* — re-explain, don't proceed on it as approval.

## Architecture

Three containers in the `devops-app` namespace on EKS, provisioned by the `terraform/` stack and
delivered by the `charts/voteball` Helm chart (synced by ArgoCD). Alongside the three Deployments the
chart also ships a **schema-migration Job** (`migrate-job.yaml`) and the **alert rules**
(`prometheusrule.yaml`):

- **frontend** — nginx serving plain HTML/CSS/vanilla JS (no build step), reverse-proxying `/api/*` to
  the backend.
- **backend** (`services/backend/`) — Flask 3.1 app. `app.py` holds all
  routes; `queries.py` holds all SQL; `db.py` holds only connection setup (`get_db`) and one-time
  schema bootstrap (`init_db`, which loads `schema.sql` then `seed.sql` — the backend is the only
  container that ever creates schema).
- **worker** (`services/worker/`) — Python loop that recomputes the
  `rollup_previous`/`rollup_upcoming`/`rollup_previous_upcoming` tables from
  `votes`/`vote_upcoming_parties`, and sends milestone SNS alerts. It is **notification-driven**, not
  a fixed timer: the backend issues `NOTIFY votes_changed` inside the vote transaction and the worker
  blocks on `LISTEN` (`notifications.py`), so results refresh ~1s after a vote instead of up to 30s.
  `WORKER_POLL_INTERVAL` (30s) remains a backstop for missed notifications and
  `WORKER_DEBOUNCE_SECONDS` (1.0) coalesces bursts — `rollups.recompute()` rebuilds the tables
  wholesale, so one recompute per vote would not scale.

**Each service directory is its own Docker build context — there is no shared Python package
between backend and worker.** The worker has its own near-duplicate `db.py` rather than
importing the backend's. This is a deliberate simplicity choice, not an oversight; don't "fix" it by
introducing a shared module unless the plan says to.

Postgres (RDS) stores: static seed data (`leagues`, `clubs`, `previous_parties`, `upcoming_parties` —
the two party tables are also admin-editable after seeding), raw votes (`votes`, `vote_clubs`,
`vote_leagues`, `vote_upcoming_parties` — a ballot can name any number of clubs across any number
of leagues, capped at 3 clubs from any one **domestic** league, so `votes` itself carries no
league/club column; `vote_clubs` records each
specific-club pick with the league tab it was picked under, `vote_leagues` records "just this
league, no specific club" picks), and worker-computed rollup tables (`rollup_previous`,
`rollup_upcoming`, `rollup_previous_upcoming` — each carries a league-scope row per distinct league
a vote touched, `club_id IS NULL`, deduped per vote+league, plus a club-scope row per specific pick
— and `rollup_national_previous`/`rollup_national_upcoming`/`rollup_national_previous_upcoming`,
counted one row per vote with no league/club dimension, since summing the league/club-scoped
rollups for national totals would over-count a multi-team ballot, plus `rollup_vote_switch` and
`rollup_national_vote_switch` backing `/api/results/switch`) that the backend reads for fast
`/api/results` responses. **There are eight rollup tables** — count them in `schema.sql`, and keep
**both** `services/backend/tests/conftest.py` and `services/worker/tests/conftest.py` `DROP TABLE ...
CASCADE` lists in step with them — there is no top-level `tests/` directory, and updating only one of
the two leaves the other suite dropping a stale set.

**A club that plays in two leagues counts toward BOTH at league scope.** `_VOTE_LEAGUES_TOUCHED_CTE`
in `services/worker/rollups.py` derives "which leagues did this vote touch" from `clubs.league_id`
*and* `clubs.domestic_league_id`, not from `vote_clubs.league_id` (which records only the tab the
pick was filed under). Club-scope rows are deliberately **not** expanded the same way — `?by=club`
filters on `club_id` with no league predicate, so a second club-scope row per vote would count one
voter twice. See `docs/design/2026-08-07-nations-league-design.md` decision 3.

`clubs.group_label TEXT` carries the UEFA Nations League's A–D divisions (nullable, seed-only —
absent from both admin club endpoints by design, since either endpoint replacing every field it
receives would otherwise let a PATCH silently null it out). Division rendering is gated on
**`leagues.has_divisions`** (a plain boolean on the league), not on whether any club present carries
a `group_label` — a dual-league club can carry its label into a league that isn't itself divided (a
16-nation overlap between the Nations League and the World Cup made exactly this happen), so
inferring "divided" from the clubs would put division headers on the wrong tab. See
`docs/design/2026-08-07-nations-league-design.md` decisions 1 and 5.

**`leagues.is_club_cup` is the second boolean of that shape, and it governs which ballots are
accepted.** `TRUE` for exactly the three UEFA club cups (Champions, Europa, Conference), it means
two things at once: a cup imposes **no pick cap of its own**, and a cup is **never a club's domestic
league**, so it is skipped when counting the ≤3-per-domestic-league cap. Two traps:

- **It is `FALSE` for the World Cup and the Nations League**, which are continental competitions but
  not club cups. A national team has no domestic league to be counted under, so marking either one
  would leave those tabs with **no cap at all** rather than a domestic-league one — the opposite of
  what "it's a continental competition too" suggests.
  `test_only_the_uefa_club_cups_are_marked_is_club_cup` pins the set in both directions.
- **The cap reads a club's own `{league_id, domestic_league_id}`, never the `league_id` its pick
  arrived under**, because which column holds the domestic league is *not* consistent: Barcelona is
  `league_id=Champions League / domestic_league_id=La Liga` and Real Betis is exactly the reverse,
  both legitimately (the two cups were seeded in opposite directions). The client files each pick
  under `domestic_league_id ?? tab`, so a label-keyed cap would bind on roughly half the ballots at
  random. Same reasoning, same fix, as `_VOTE_LEAGUES_TOUCHED_CTE` above.

A club whose domestic league this app does not seed (Lugano and Thun are Swiss; there is no Swiss
tab) lands in no bucket and is **deliberately uncapped** — the rule binds where a domestic league is
known. The cap is enforced **twice**, in `services/backend/app.py` and `services/frontend/vote.js`;
a client looser than the server offers ballots the API then rejects with an error the form cannot
explain.

### Backend request-handling pattern

Every route acquires its own `psycopg2` connection via `db.get_db()` (no pooling) and must guarantee
`conn.close()` on every exit path, including unexpected exceptions — use `try/finally`, not scattered
`conn.close()` calls in each branch (see `results()` and `vote()` in `app.py` for the established
shape). `queries.py` functions that mutate data must `conn.rollback()` in a broad `except` before
re-raising, not just catch the one expected constraint-violation error, since this is the failure mode
that leaks connections on a public endpoint (see `insert_vote`'s history in `queries.py`).

Admin endpoints (`/api/admin/...`) are protected by the `require_admin` decorator in `app.py`, which
verifies an `Authorization: Bearer <token>` header — a signed, 12-hour-expiring token
(`itsdangerous.URLSafeTimedSerializer`) issued by `POST /api/admin/login` after checking a username
and `werkzeug`-hashed password (`ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH`/`ADMIN_SESSION_SECRET` env
vars). Reuse this decorator for any new admin route — don't hand-roll the check.

### Observability

`db.get_db()` on both backend and worker connects with `psycopg2.connect(..., connect_timeout=5)` —
**never remove this.** Without it, a blocked network path to RDS (a NetworkPolicy break, a routing
problem, RDS itself unreachable) makes the connect call **hang** instead of failing. A hung request
never completes, so nothing gets counted — not even the error counter — and the request-ratio SLIs
(`voteball:availability:ratio5m` and friends) simply have no data point to include it in. This was a
real, live defect (found by the 2026-08-18 drills, `docs/eks/evidence/2026-08-18-drill-1-controlled-
5xx.txt`): a two-hour total API outage rendered as `availability = 1`, perfect, because every failing
request was still in-flight, not failed. `connect_timeout=5` is what turns "the database is
unreachable" into a fast, countable error instead of an invisible one.

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

**Jenkins exposes two Prometheus metric families that are not interchangeable, and picking the wrong
one for a dashboard panel or alert shows a flat, healthy-looking zero instead of an error.** The
bundled Metrics plugin's `jenkins_*_value` gauges (`jenkins_queue_size_value`,
`jenkins_executor_count_value`, `jenkins_node_online_value`) read `0` almost all the time on this
cluster — truthfully, since the Kubernetes cloud provisions agents on demand and nothing sits queued or
connects between builds — while the `prometheus` plugin's own `default_jenkins_builds_*` family
(build counts, durations, health scores) carries real non-zero data throughout the same window. Both
are correct for what they measure; verify which family a metric actually belongs to by querying it
live, never by guessing from the name (`docs/design/2026-08-17-observability-design.md`'s "Drill
outcomes" section and `charts/observability/values.yaml`'s `queueMetric` comment both record this being
gotten wrong once already). `JenkinsQueueStuck` (`jenkins_queue_size_value > 0` for 15m) is proven,
but only on the second attempt, and the way it was proven is the point: killing an agent mid-build
*aborts* the build rather than queueing it, so a drill built around that mechanism can never reach a
non-zero queue size. Reaching the condition needs agent **provisioning** to fail — a `ResourceQuota`
of `pods=1` on the `ci` namespace — after which the alert fired end to end
(`docs/eks/evidence/2026-08-18-rerun-drill-5-jenkins-queue-stuck.txt`). It also depends on the Jenkins
ServiceMonitor being enabled, which is gated on a controller-image rebuild carrying `prometheus.jpi`.

### API surface

The full route table — every endpoint with its method, auth, request body, validation rules and
error codes — lives in the **`voteball-api` skill** (`.claude/skills/voteball-api/SKILL.md`).
Invoke it before adding, changing or calling any endpoint.

Two things about it that the route signatures do not show:

- `/api/vote`'s validation rules are enforced **twice** — the client validates all of them before
  submitting, so a client-side change without the matching server-side one silently loosens nothing,
  but the reverse leaves the form accepting ballots the API rejects.
- `/api/admin/votes` assembles `team_picks` from **separate queries** against `vote_clubs`/
  `vote_leagues`, not a joined `array_agg` — a join would cartesian-inflate `upcoming_party_ids`
  alongside it.

Frontend pages: `index.html`/`vote.js` (voting form, posts to `/api/vote`), `results.html`/`results.js`
(dashboard, reads `/api/results`), `admin.html`/`admin.js` (unlinked from the public pages — party
CRUD, vote reassignment for merges/splits, and votes list/delete, gated by username/password login
issuing a session-stored Bearer token). All three render backend-derived names via
`createElement`/`textContent`, never `innerHTML` string interpolation — `previous_parties`/
`upcoming_parties` names come from an external API and admin input respectively, neither is safe to
trust as pre-escaped HTML.

### Languages (English, Hebrew, Russian)

Two independent layers, and adding a language means doing **both**:

- **Interface strings** — the `DICTIONARY` in `services/frontend/i18n.js`, keyed language → string
  id. All three language objects must carry **identical key sets and identical `{placeholder}`
  tokens**; `t()` returns the key itself on a miss, so a gap renders `voteHeroTitle` on the page
  rather than throwing. Language handling reads `SUPPORTED_LANGS`/`RTL_LANGS`/`NAME_FIELD_BY_LANG`
  at the top of that file — add a language there, not by extending `en`/`he` conditionals.
- **Entity names** — `name_en`/`name_he`/`name_ru` **columns** on `leagues`, `clubs`,
  `previous_parties`, `upcoming_parties`, selected by `localizedName()`, which falls back to
  `name_en`. `name_ru` is **nullable and optional in the admin API** — requiring it would 400 every
  existing admin client and block saving any entity with no Russian name yet. The cost is that
  coverage can rot silently as clubs are added.

**Any admin PATCH that forwards a subset of fields must forward every name column.** Those endpoints
replace all fields, so an omitted name is written as `NULL`. `patchClubLeagues` in `admin.js` (behind
the per-competition "Add to UEFA Champions League" / "Add to UEFA Europa League" buttons, which are
generated from `CONTINENTAL_COMPETITIONS`) is the one call site that does this, and it resends
`name_en`/`name_he`/`name_ru`/`logo_url` for exactly this reason.

**Russian names must be Cyrillic, and a homoglyph will pass review.** `РААМ` typed on a Latin
keyboard layout is `PAAM` — visually identical, a different string, and it breaks Russian text
search and collation. `test_migration.py::test_seeded_russian_names_are_cyrillic` asserts the
property; don't rely on reading the file.

Fonts: Heebo and Anton have no Cyrillic. Roboto's Cyrillic subset is declared under the **same
`Heebo` family** (Heebo's Latin derives from Roboto, so it matches rather than approximates) and the
browser picks it by `unicode-range`, so body text needs no `:lang(ru)` rule. Display headings use
Oswald via `--font-display-ru`, mirroring the `:lang(he)` rules in `style.css`.

## Deployment

**`docs/deploy.md` is the plain-language runbook** — follow it for real deploys. Summary of the split:

- **Terraform (`terraform/`)** builds everything AWS: dedicated VPC, EKS cluster + Spot node group,
  OIDC/IRSA roles, ECR, ACM, S3, SNS, Secrets Manager (container only), RDS (restored from a pinned
  snapshot), **and every platform add-on** via `helm_release`/`aws_eks_addon` (AWS Load Balancer
  Controller, External Secrets Operator, Cluster Autoscaler, Node Termination Handler, CloudWatch
  pod logging, metrics-server, external-dns, ArgoCD, kube-prometheus-stack, and the ECK operator).
  Needs `terraform/voteball.tfvars` (gitignored) and `-var-file=voteball.tfvars`.

  **The CloudWatch add-on is deliberately cut down to pod logs only, and the parts that are off cost
  money per day when on.** `containerInsights` and `applicationSignals` were both billing this
  account for a second copy of what `kube-prometheus-stack` already collects for free — measured
  2026-08-03 at **$3.00/day of `CW:ObservationUsage`** ($30.03 in July) plus ~3.1 GB/day of log
  ingestion, 61% of it `Type=ControlPlane` records duplicating Prometheus' apiserver scrape.
  Application Signals was also the sole source of ~89k monthly X-Ray traces. Fluent Bit's pod-log
  tail is scoped to `devops-app` only (it was every namespace; `ci`/`argocd`/`monitoring` were ~95%
  of the volume). All of this lives in `terraform/addon-cloudwatch.tf` with the numbers in comments
  — **read them before re-enabling anything there.** Note the Fluent Bit override *replaces* the
  add-on's default `application-log.conf` rather than merging into it, so a dropped `[OUTPUT]` block
  fails silently: the agent stays healthy and no logs arrive.
- **Helm (`charts/voteball`)** is the app itself (namespace `devops-app`): 3 Deployments, Services,
  Ingress→ALB, ConfigMap, ExternalSecret, 4 ServiceAccounts, NetworkPolicies, HPA, PDBs, backup CronJob.
  **ArgoCD** syncs it from the **`release`** branch (GitOps) — the chart is the single authoring path.
  `release` is written only by `application-cd`; pushing to `master` cannot reach the cluster.
- **Helm (`charts/observability`)** is dashboards-and-alerts-as-code for the `observability` namespace:
  the six Grafana dashboards (provisioned as ConfigMaps via `.Files.Glob`, not clicked together), the
  Kubernetes/Jenkins/monitoring-system `PrometheusRule`s, that namespace's own default-deny
  NetworkPolicies, and — since the 2026-08-24 Grafana data sources pass — the PostgreSQL/CloudWatch/
  GitHub datasource ConfigMaps (`templates/datasources.yaml`) and the ExternalSecret/SecretStore that
  project `grafana_ro`'s password and the GitHub PAT into the Grafana pod (`templates/
  externalsecret.yaml`, gated `enabled: false` by default — see `docs/deploy.md`'s "Optional, manual"
  section and `docs/design/2026-08-24-grafana-datasources-design.md`). It is a **second ArgoCD
  Application with its own `AppProject`** (both declared in
  `argocd/voteball-application.yaml.tmpl` alongside `voteball`'s), synced from `release` the same way —
  the app's own ServiceMonitors and SLI/SLO recording rules stay in `charts/voteball` instead, next to
  the Services and alerts they describe. kube-prometheus-stack itself (Prometheus/Grafana/Alertmanager,
  the PVC, retention, SNS routing) is a `helm_release` in `terraform/addon-monitoring.tf`, not this
  chart — same Terraform-vs-Helm boundary as everywhere else: the platform reaches the cluster by
  `terraform apply`, the configuration on top of it by `git push`.
  **The Jenkins ServiceMonitor lives in `charts/jenkins-support`, not here** — it deploys with the
  Jenkins release it scrapes — and its enablement is coupled to a controller-image rebuild: the
  `prometheus` plugin is baked into the image from `ci/jenkins/plugins.txt`, and the ServiceMonitor is
  gated on `serviceMonitor.enabled`, which Terraform only flips to `true` once `jenkins_image_tag` (in
  the gitignored `terraform/voteball.tfvars`) points at an image that actually contains
  `prometheus.jpi`. **Committing `plugins.txt` alone changes nothing** — plugins are baked into the
  controller image, and (per the Jenkins note below) the release is owned by Terraform, not ArgoCD;
  turning the ServiceMonitor on ahead of the matching image/tag rebuild would scrape a target that
  404s forever and page `PrometheusTargetDown` on a repeating schedule for nobody to fix without that
  build.
- **ArgoCD itself is configured in exactly two files and nothing else**: `terraform/addon-argocd.tf`
  (the `helm_release` and every `argocd-cm`/`argocd-rbac-cm` key) and
  `argocd/voteball-application.yaml.tmpl` (the `AppProject` **and** the `Application`, one two-document
  template — the AppProject must render first, kubectl applies a stream in order). **Nothing is
  configured through the UI.** `./scripts/render-argocd-app.sh --check` enforces that: it fails on a
  live/template mismatch, on any `Application`/`AppProject` this repo does not declare, and on any
  hand-registered repo or cluster credential. It is a *separate* check because ArgoCD cannot do it —
  `selfHeal` reconciles `charts/voteball`, but nothing reconciles the `Application` pointing at it, so
  a UI edit to sync policy or destination is the one drift GitOps cannot self-correct.
  The `voteball` AppProject pins source repo + destination namespace and sets
  `clusterResourceWhitelist: []`; see `charts/voteball/CLAUDE.md` before adding a cluster-scoped kind.
- **ECK operator (`terraform/addon-eck.tf`) — the ECK add-on, added for EFK logging.** Terraform-owned
  like ArgoCD itself, and for the identical reason: its chart installs 17 cluster-scoped objects (12
  CRDs, 3 `ClusterRole`s, 1 `ClusterRoleBinding`, 1 `ValidatingWebhookConfiguration`), and every
  AppProject's `clusterResourceWhitelist: []` makes ArgoCD structurally unable to manage them. Installs
  into `elastic-system`; `managedNamespaces` is scoped to `logging` alone so it never reconciles a
  custom resource anywhere else in the cluster. The namespaced objects it reconciles — `Elasticsearch`,
  `Kibana`, `Fluentd` — live in **Helm (`charts/logging`)**, delivered by its own third ArgoCD
  Application/AppProject the same way `charts/observability` is: gated `enabled: false` until the
  operator's CRDs exist (see the forkability/gating notes below), then flipped on and verified by
  `scripts/logging/verify-efk.sh` (deploy step 11e). **Teardown order is the reverse of install, and
  specifically the opposite of what you'd guess**: `destroy.sh` deletes the `Elasticsearch`/`Kibana`
  custom resources first, then `helm uninstall`s the `logging` release, and only then the operator
  itself — because the operator's `ValidatingWebhookConfiguration` intercepts every write to
  `*.k8s.elastic.co` objects, and removing the operator first leaves those deletes with no backend
  left to answer. See `docs/design/2026-08-27-efk-logging-design.md`.
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

- **`./scripts/deploy.sh` / `./scripts/destroy.sh`** run the full ordered sequence (both stop for
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
- **`./scripts/sync-values-from-tf.sh` owns ten fields in `values.yaml`** — `image.registry`,
  `image.tag`, `config.DB_HOST`, `config.S3_BUCKET`, `config.SNS_TOPIC`, `ingress.host`,
  `ingress.certificateArn`, `ingress.wafAclArn`, `backup.roleArn`, `worker.roleArn`. The committed file
  carries the **real, current** values, not placeholders — ArgoCD deploys from `release`, so it has to
  (see the forkability note at the top). **Never hand-edit them** — they change on every rebuild. `--check`
  fails on drift *and* verifies `image.tag` names an image that exists in ECR. Its only test is
  `scripts/tests/test-sync-values.sh` (runs offline via `SYNC_STUB_*` env vars); **extend it whenever
  you add a managed field** — it is what catches the `backup.roleArn`/`worker.roleArn` cross-assignment
  that a naive `sed` would cause.
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

**Read the `release` branch by CONTENT, never by ancestry.** `promote-to-release.sh` builds each
release commit with `git read-tree`, not a merge, so a `master` commit is *never* an ancestor of the
release commit that carries it — `git merge-base --is-ancestor <sha> origin/release` returns false
even when the tip literally reads `release: <sha>`. Use `git show origin/release:<path>` (which is
what `current-release-tag.sh` and `previous-tag.sh` already do, correctly). Anything that checks
promotion by ancestry reports "not promoted" forever.

- **Secrets:** `./scripts/seed-eks-secret.sh` takes `ADMIN_USERNAME`/`ADMIN_PASSWORD` from the
  environment or a silent prompt and writes them to Secrets Manager; nothing secret enters git or
  tfstate. `DB_PASS` **must** match `db_password` in `terraform/voteball.tfvars` — so it now defaults
  to reading it straight from there (`tf_db_password` in `scripts/lib/config.sh`), which makes the
  match automatic; pass `DB_PASS` in the environment only to override.
- **CI/CD is Jenkins, running IN the cluster** (namespace `ci`), installed by Terraform as a
  `helm_release` (`terraform/addon-jenkins.tf`) of the official chart, configured by JCasC
  (`ci/jenkins/jenkins.yaml`), and split (since 2026-08-04) into **two pipelines**: `application-ci`
  (`Jenkinsfile-ci`) tests, builds, scans and pushes; `application-cd` (`Jenkinsfile-cd`) promotes,
  deploys, verifies and rolls back. CI never deploys and holds no cluster credentials; CD never
  builds and holds a strictly read-only Kubernetes Role. Pushing app code to `master` fires a GitHub
  webhook → `application-ci` (guard → validate → lint → test → build → Trivy → push → publish
  metadata) → triggers `application-cd` (validate → promote `image.tag` `[skip ci]` → ArgoCD sync →
  wait → verify → smoke test, with automatic rollback on failure). Two parameters worth knowing:
  `application-ci`'s `FORCE_BUILD` builds even when the changeset touches nothing under `services/**`
  (needed for the empty-changelog case G3b guards against — see the Guard-stage note below);
  `application-cd`'s `ROLLBACK_DEPTH` bounds rollback recursion — without it, a rollback that itself
  fails would trigger another rollback, which could fail the same way, forever, pushing a commit each
  cycle. `./scripts/build-push-ecr.sh` does
  the build and push by hand -- **it does NOT scan; it contains no Trivy call at all** (verified
  2026-08-27, and the images this repo ships to production on a rebuild therefore reach ECR
  unscanned: `application-ci` is the only thing that runs the Trivy gate). It is the **only** way to
  build while the cluster is destroyed
  (there is no CI without a cluster). Agent pods authenticate to AWS via **IRSA** — CI's
  `jenkins-agent` ServiceAccount gets ECR push, CD's `jenkins-cd-agent` gets ECR read-only, and the
  controller itself carries no AWS role at all. Region, cluster name, GitHub repo and app domain
  arrive as **pod environment variables** set by Terraform — the equivalent of the retired EC2 host's
  global environment variables, and the reason a hardcoded region or prefix in either `Jenkinsfile-*`
  or `ci/jenkins/jenkins.yaml` would be a bug. **See `docs/cicd.md`** for the full flow, the
  first-time setup runbook, and failure modes; the split's design rationale — including why ArgoCD
  stays the applier instead of a direct `helm upgrade`, and how rollback works — is in
  `docs/design/2026-08-04-cicd-split-design.md`.

  **Jenkins is a platform add-on, not the application** — the opposite of `charts/voteball`. Changes to
  the Jenkins release reach the cluster by `terraform apply`, **not** by committing to `master` (ArgoCD
  does not manage it; Terraform does, the same way it owns ArgoCD, ESO and external-dns). Committing a
  change to `ci/jenkins/jenkins.yaml` or `terraform/addon-jenkins.tf` and walking away does nothing
  until someone runs `terraform apply`.

  **`JENKINS_HOME` is a PersistentVolumeClaim backed by EFS, not an `emptyDir`.** The node group is
  100% Spot, reclaimed roughly once a day, and the reason an *EBS*-backed PVC was rejected still
  holds: an EBS volume is locked to one Availability Zone, so it would need every reschedule to land
  back in the same AZ or the pod hangs `Pending` forever. **EFS has a mount target in every AZ**, so
  it carries none of that lock-in — a rescheduled controller pod rebinds the same volume regardless of
  which AZ it lands in. That is why the fix is EFS (`terraform/addon-efs.tf`), not an EBS PVC pinned
  to one AZ, and not staying on `emptyDir` — the course brief for the 2026-08-04 CI/CD split lists
  persistent Jenkins-home storage as a mandatory component. Build history (last 20 builds) now
  survives a routine Spot reclaim. Removing the Jenkins release (`scripts/jenkins/uninstall-jenkins.sh`
  or a targeted `terraform destroy`) deletes the PVC — it carries no `resource-policy: keep`
  annotation — but the `efs-sc` StorageClass's reclaim policy is `Retain`, so the underlying EFS
  access point and its data survive as a `Released` PV; a reinstall provisions a **new, empty** PVC
  and does not rebind to the old one automatically, so recovering that history needs a manual PV
  rebind. It is gone for good only on a full `terraform destroy` of the EFS resources themselves —
  see `docs/cicd.md`'s "Running the instance" for the three-tier breakdown. The durable
  record of what was *deployed* was never the build log regardless — it is the
  `release: <sha> (image tag <tag>)` commits on the **`release`** branch, which never expire.
  (They were `ci: image tag <sha> [skip ci]` on `master` until the 2026-08-23 branch split.)

  **The `buildkit` container is the one container in this entire project that runs
  `allowPrivilegeEscalation: true` plus `SETUID`/`SETGID`.** Rootless BuildKit builds inside a user
  namespace, and mapping UIDs into that namespace needs those two things — without them the pod looks
  healthy (4/5 containers) and the build just hangs forever with nothing logged. It is still **uid
  1000, not privileged, no host devices, no host paths** — nothing like Docker-in-Docker's
  `privileged: true`, which is why DinD was rejected for this pipeline in the first place. Every
  container in `devops-app` still runs `allowPrivilegeEscalation: false`; **do not "tidy" this one
  container to match them** — rootless BuildKit cannot start without the exception, and it is scoped to
  one CI pod in a namespace whose NetworkPolicy already denies it any route to RDS or `devops-app`.

  **Jenkins traces every `sh` step with `set -x`, which echoes a command AFTER argument
  expansion — so any secret fetched at RUNTIME (as opposed to injected via `withCredentials`, which
  Jenkins masks in the log) leaks in full the moment it reaches an argument position**, e.g. as a
  `printf`/`$(...)` argument. This leaked a live ECR token into committed CI evidence on 2026-08-04
  (fixed in `Jenkinsfile-ci`'s image-auth step: write straight to a file, read it back with
  `cat`/a pipe, never as an argument). The counter-constraint is that `aws ecr get-login-password`
  emits a trailing newline that a plain file redirect preserves, which corrupts the base64 auth
  string it feeds into — so the newline still has to go, just without reintroducing the leak: use
  `tr -d '\n' < file`, never `$(...)`, which trims the newline but never puts the token back in
  argument position. State both constraints together — the trailing fix for one re-broke the other
  once already.

  **Both build caches live in ECR** (`${cluster_name}-buildcache`, `${cluster_name}-trivy-db`), and
  both repos **must stay `MUTABLE` and outside `local.ecr_repos`** in `terraform/ecr.tf`. That set is
  `IMMUTABLE` because a git-SHA tag must never be silently overwritten; a cache tag is *rewritten on
  every build* by design, so adding either repo to that set fails every build's cache export with
  "cannot overwrite immutable tag" — at the end of a long build, not the start.

**Do not remove the Guard stage from `Jenkinsfile-ci`, or `scripts/ci/should-skip-build.sh`** — and
note that since 2026-08-23 **nothing writes the `[skip ci]` marker any more**, which makes the Guard
look even more like dead weight than it did before. It is not. Jenkins has no native `[skip ci]` (that
is a GitHub Actions feature), and the Guard is the only thing standing between a master-pushing
promotion and an unbounded, billable build loop across both pipelines that also rolls production pods
continuously. It must already be in place *before* anyone reintroduces one. `deploy.sh` step 9 still
commits to `master` today. Proven, not theoretical: build 5 in `docs/cicd.md` is the webhook firing on
Jenkins' own commit and being stopped by exactly this stage.

**The Guard is range-aware and must stay that way.** `should-skip-build.sh --subjects` reads every
commit subject since `GIT_PREVIOUS_SUCCESSFUL_COMMIT` and skips only if *all* of them carry the
marker; the single-message form is the fallback for a first build or a rewritten base. Reading only
the tip is what let the 2026-08-21 queued-build race hide a source commit behind a promotion commit
so that nothing ever built it — reported as `NOT_BUILT`, which reads like a pass.
`test-ci-guards.sh` pins the incident as a regression case.

**Jenkins is configured by JCasC, not by clicking — but the mechanism is `terraform apply`, not a
reboot of a hand-managed host.** `ci/jenkins/jenkins.yaml` is loaded into the Helm release's
`controller.JCasC.configScripts` and applied by the chart's config-reload sidecar (plugins, admin
user, authorization, the Kubernetes cloud, both agent pod templates, all credentials, and both jobs —
`application-ci` and `application-cd`), so **UI changes are lost the next time the controller
restarts** — which, on Spot, is roughly
daily whether you touch anything or not. Edit the YAML, commit, then run `terraform apply` to push it
to the running release; committing alone changes nothing (see the platform-add-on note above).
Secrets come from Secrets Manager (`voteball/jenkins`, seeded by `./scripts/seed-jenkins-secret.sh`),
synced into a Kubernetes Secret by External Secrets Operator and projected as pod environment
variables — a Kubernetes Secret carries the deploy key's trailing newline natively, so the old
one-file-per-value workaround for that is gone. **The GitHub plugin is configured by the official
chart, not by hand-written XML** — the EC2-era `hookSecretConfigs`/two-file/SHA-256 workaround
existed only because that plugin version couldn't be data-bound by JCasC; it no longer applies.

**Terraform state lives in S3** (`<cluster_name>-tfstate-<account_id>`), one bucket, **one key**
(`voteball/main.tfstate` — the separate `voteball/jenkins.tfstate` is retired along with the EC2
stack), with versioning and S3-native locking
(`use_lockfile` — *not* a DynamoDB table; that argument is deprecated, and `required_version` is
`>= 1.11.0` for this reason). **The bucket belongs to no stack and must never be added to
`scripts/destroy.sh`** — a CI server or the app stack disappearing on teardown is recoverable from
git and Secrets Manager; this bucket disappearing mid-teardown would delete the record of what is
being deleted, with nothing left to reconstruct it from. `backend.hcl` is **generated by
`./scripts/bootstrap-tf-backend.sh` and gitignored**, because a `backend` block cannot interpolate
variables and the bucket name embeds the AWS account id — so `terraform init` needs
`-backend-config=backend.hcl`, and without it fails on incomplete backend configuration rather than
silently using local state. See `docs/design/2026-07-21-terraform-remote-state-design.md`.

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
- **The nightly `pg_dump` in S3 is not teardown insurance.** `terraform/s3.tf:9` sets
  `force_destroy = true`, so `terraform destroy` deletes the rollups bucket and every backup in it,
  during the same run it would supposedly be insuring. The layers that do survive are the final
  snapshot and **retained automated backups** (`delete_automated_backups = false`). Don't count the
  dumps when deciding whether a teardown is safe.

Four teardown behaviours `destroy.sh` handles that a manual `terraform destroy` does not:
- **`./scripts/cleanup-stale-dns.sh`** removes this cluster's Route53 records if external-dns didn't get
  to it first (it only reconciles on a timer and can be destroyed before noticing the deleted Ingress).
  Gated on the ownership TXT (`external-dns/owner=voteball`), so apex/MX/DKIM records are never eligible.
- **An orphaned-ENI reaper** runs in the background during destroy. The VPC CNI leaves detached
  `aws-K8S-*` interfaces when nodes terminate, and they make Terraform retry `DeleteSubnet` against a
  `DependencyViolation` for 10–20 minutes. See `docs/deploy.md` troubleshooting for the manual command.
- **Pre-uninstalling `voteball`/`jenkins`/`jenkins-support` via Helm while the cluster is still
  healthy**, and **one bounded automatic retry** (state-rm on `helm_release.*`/`kubernetes_*` only,
  never `aws_*`) if `terraform destroy` still hangs — see above for both.
- **State-lock detection** — prints the exact `force-unlock` recovery instead of failing opaquely, and
  never force-unlocks on its own (see above).

**A failing command whose exit status is swallowed by the thing that printed it — three instances,
three different mechanisms, one bug.** This is the most-repeated defect shape in this repository, and
it is worth grepping for before writing anything that shells out:

- **Pipe position.** `terraform apply | tail` reports the exit status of `tail`, so a FAILED apply
  reads as 0.
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
evidence built on it gets believed. `set -euo pipefail` is necessary and covers none of the three:
not a pipeline's non-final stage, not a `$(...)` whose output is merely printed, not a request that
succeeded against the wrong URL. **And the three need different fixes, so "check the exit status" is
not the lesson:**

| Sub-type | Fix | How it is found |
|---|---|---|
| A discarded exit status | capture it into a variable and branch on it | reading the code |
| A race against state that has not arrived | a completion condition, or a retry | running it twice |
| A pattern that can never match | feed the check input you KNOW should match, once | **only** by that |

The third is the worst and arrived last (2026-08-24, drill 4: `grep '^gate:'` against Jenkins console
lines, every one of which carries a timestamp prefix — the anchor could never match, so the section
was empty and correct). No amount of reading `grep '^gate:'` reveals that, and a retry cannot help.
Worse, its empty result is not merely indistinguishable from "nothing to report" — it is
indistinguishable from a **correct negative**, which is a legitimate outcome nobody has any reason to
investigate. Exercising a check against known-present input at least once is the only defence, and it
is the same discipline as proving a test can fail before trusting it to pass.

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
`put-secret-value … --output text`, plus two in `capture-evidence.sh`. Steps 3b and 7b are the
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

**Do not add `ignore_changes` to `final_snapshot_identifier`** in `database.tf` — the provider reads it
from state at destroy time, so that silently disables the final snapshot *and* wedges the VPC teardown.
There's a comment there explaining why; keep it.

### Party ideology axes (`seed.sql`)

Both party tables carry three numeric axes — `economic`, `security`, `religiosity` (each −3..+3,
**nullable**, where `NULL` means "no stated position" and `0` asserts a confirmed centrist one) —
plus categorical `bloc`/`sector` and free-text `tags`. `seed.sql` holds the values;
`docs/party-classifications.md` holds the reasoning; keep them apart.

**The full revision procedure is in `services/backend/CLAUDE.md`**, which loads whenever you work
under that directory — read it before touching `seed.sql`. Four rules from it are repeated here
because getting them wrong destroys data rather than just being wrong:

- **The six ideology columns (and `group_label`) are deliberately UNCONDITIONAL — do not add `AND
  bloc IS NULL` or an `admin_edited` check.** A guard makes every later edit unreachable on an
  already-seeded production database.
- **Names, `logo_url` and `domestic_league_id` are admin-ownable, and column-level provenance
  protects them, not a per-statement guard.** `admin_edited TEXT[]` on each of the four entity
  tables lists the columns a human has actually changed through the admin UI; `seed.sql`'s single
  `UPDATE` per table writes every other admin-ownable column unconditionally. This is what let the
  file drop the roughly twenty patch statements it used to grow by — a corrected value now reaches
  an already-seeded database by editing the literal, the way the six ideology columns always could.
- **Identity is `seed_key`, a slug assigned once and never displayed, writable through the API, or
  used to rename anything** — not a display name. `seed_key IS NULL` means "created through the
  admin UI," so `seed.sql` never touches that row, including on removal. Adding an entity is one row
  in a table's `VALUES` block, regenerated via `scripts/seed/generate-tables.py`, not hand-typed.
  `seed.sql` is now **621 lines / 47 statements** (from 1,276 lines / 78 statements), with **zero**
  patch statements — verify with `grep -c ';\s*$' services/backend/seed.sql` rather than trusting
  this number, it will drift the next time the file changes.
- **Restructuring `seed.sql` must be proven data-neutral, now via
  `scripts/seed/verify-neutrality.sh <production-dump.sql> <old-git-ref>`** — it builds three
  databases (an old-seeded baseline, the same dump migrated through the new files, and a fresh
  install) and diffs them, excluding timestamps and keying rows by their natural name column rather
  than sorting whole-row text. The old-seeded-vs-migrated diff is the one that matters — it is the
  only one built from the same production dump on both sides, so it is the only one that proves an
  *already-seeded* database (the only kind that exists in production) ends up where it started.

### Reverse-seeding: keeping seed.sql in sync with admin-UI edits

Admin-curated data (logo URLs, renames) lives only in the live RDS instance until someone backfills it
into `seed.sql`. `scripts/sync-seed-from-rds.sh` used to automate this, but it tunnelled to RDS over
SSH through the k3s EC2 node — which EKS does not have — so it was **removed on 2026-07-20**. Porting
it would mean replacing the SSH tunnel with `kubectl port-forward` through a backend pod; the original
is in git history.

### Secrets

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

## Common commands

### Terraform (`terraform/` — the live stack)

```bash
cd terraform
# State lives in S3, and the backend block is PARTIAL by design (a backend block cannot interpolate
# variables, and the bucket name embeds the AWS account id). backend.hcl is generated + gitignored:
../scripts/bootstrap-tf-backend.sh          # idempotent; creates the bucket, writes backend.hcl
terraform init -backend-config=backend.hcl  # add -upgrade after adding a module; -migrate-state once
terraform validate
terraform fmt -recursive   # run before committing any .tf change
terraform plan  -var-file=voteball.tfvars
```

`terraform apply` creates real, billed AWS resources (EKS control plane, NAT, nodes, RDS, ALB ≈
**≈$8.50/day** while up — a measured full 24h, 2026-08-07, ≈$256/mo continuous; July 2026 actually billed $285.07 at ~63% uptime; ≈$0.19/day torn down) — treat it as a confirm-before-running step, never automatic. Pins that matter: **`aws ~> 5.0`**
(the EKS module v20 caps the provider at `< 6.0`) and
**`cluster_version`** — keep it on a *standard-support* EKS release or the control plane costs 5×
(pinned at **1.36** since the 2026-07-30 in-place upgrade; **standard support ends 2027-08-02**; see
`docs/maintenance.md`)
(`aws eks describe-cluster-versions --region <your region>`). Community chart/add-on versions drift fast;
verify with `helm search repo <chart> --versions` before pinning.

### Jenkins (`ci` namespace — installed by the main Terraform stack)

```bash
cd terraform
terraform apply -var-file=voteball.tfvars   # same stack, same state; re-applies the Jenkins release too
kubectl port-forward -n ci svc/jenkins 8080:8080   # then browse http://localhost:8080
```

There is nothing to start or stop — it runs whenever the cluster does, and goes with it on
`terraform destroy`. Webhook URL: `https://jenkins.<app_domain>/github-webhook/`.

### CI/CD scripts (`scripts/ci/`, `scripts/jenkins/`)

**Thirteen scripts** (count them: `ls scripts/ci/*.sh | wc -l` — this number has been wrong twice
now: it said "Five" while the directory held eight, and was corrected to "Twelve" only to be stale
again within the same session, because `verify-deployed-image.sh` landed an hour later. Derive it,
do not read it from here), each one pipeline decision point extracted so it can be tested without
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

**The suite is 26 tests as of 2026-08-25** — read it off `run-ci-suite.sh`'s own final output line
rather than from here. `PYTHON_GROUP`, `GIT_GROUP` and `SKIP` are exhaustive and the runner fails if
a file in `scripts/tests/` appears in none of them, so the count moves whenever a test is added and
this sentence will go stale before the runner does.

**`Jenkinsfile-ci`'s "Script tests" stage runs `run-ci-suite.sh` in TWO containers, and until
2026-08-11 nothing ran these tests at all** — CI ran `pytest` for `services/{backend,worker}` and stopped, so every guard
protecting the pipeline itself was covered by a test somebody had to remember to run. Any of them
could have been deleted with every build staying green. **`run-ci-suite.sh`'s `PYTHON_GROUP`,
`GIT_GROUP` and `SKIP` lists are exhaustive and it fails if a test file appears in none of them —
whichever group is being run**, so a new test cannot slip through the gap between the two groups, and
adding one forces a one-line decision. A glob would silently pick up a future helm-dependent test and
break every build; an unchecked hand-list would silently drop a new test and protect nothing. It also
fails if a listed test no longer exists. Three are skipped for tools the agent lacks (`helm`, `gh`, `curl`); moving one
into a group means adding that tool to an image, not loosening the test.

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
gitignored files do not.

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

### Per-directory guidance (loads automatically when you work there)

The build, test and gotcha notes for each component now live next to the code, in a `CLAUDE.md` that
loads only when Claude is working under that directory:

| File | Covers |
|---|---|
| `services/backend/CLAUDE.md` | `seed.sql` ideology-axis revision, the real-Postgres test setup, `requirements.txt` vs `requirements-dev.txt`, the Dockerfile `COPY` rule |
| `services/worker/CLAUDE.md` | why the worker duplicates `db.py`, its test setup, the Dockerfile `COPY` rule |
| `services/frontend/CLAUDE.md` | the Dockerfile `COPY`-by-name rule, `logos/` as the directory exception, the no-hotlinking rule |
| `charts/voteball/CLAUDE.md` | `helm lint`/`template`, the migration Job's `post-install,pre-upgrade` split, the `release: kube-prometheus-stack` alert-rule label |

Two rules from those files are repeated here because they bite from outside the directory too:

- **Adding any new source file (backend, worker, or frontend) requires updating that service's
  `Dockerfile` `COPY` line.** A file on disk but missing from `COPY` is absent from the image with
  **no build error** — it surfaces as a runtime `ImportError` or a 404.
- **ArgoCD owns the chart release**, so changes reach the cluster by going through `application-cd`,
  which promotes them to the `release` branch — **not** by committing to `master` (which no longer
  deploys anything by itself) and not by running `helm upgrade` by hand. A hand-run upgrade of a chart
  that **differs** from what ArgoCD has fails
  on server-side-apply field ownership (`conflict with "argocd-controller"`). An *identical* chart
  applies clean, because server-side apply grants two managers co-ownership of a field as long as they
  apply the same value. Two corollaries, both found the hard way on 2026-08-10:
  - A manifest the API server **normalises** (an empty list literal such as `to: []`, which it drops)
    can never match what it stored, so it conflicts forever even when the chart is identical.
    `scripts/ci/validate-repo.sh` now fails the build on empty list literals.
  - **`deploy.sh` step 10 no longer runs `helm upgrade` when ArgoCD already manages the release** —
    it can't. Step 9 pushes a *new* image tag and step 10 applies it while ArgoCD still owns `.image`
    at the old one, so the values differ *by design* and the conflict is guaranteed on every re-run.
    Step 10 now branches: Helm on a fresh cluster (no `Application` exists until step 11), and
    `scripts/wait-for-argocd-sync.sh` otherwise, which nudges ArgoCD and waits for Synced/Healthy
    **at the pushed SHA** — checking the revision matters, since an Application that hasn't noticed
    the new commit reports Synced/Healthy about the old one. Test:
    `scripts/tests/test-argocd-sync-wait.sh` (offline, stubs the cluster via `ARGOCD_STUB_*`).

### Doc claims that drift (check these before trusting them)

Two audit passes on 2026-07-26 found seven stale claims; every one was mechanically checkable.

- **The API surface table** (now `.claude/skills/voteball-api/SKILL.md`) vs
  `grep -oE "@app\.route\('[^']+'" services/backend/app.py` — 10 routes (the whole clubs/leagues
  admin block) were undocumented until that audit.
- `docs/deploy.md`'s numbered steps vs `grep -E '^\s*step "' scripts/deploy.sh`.
- The sync-managed field list vs the `managed` dict in `scripts/sync-values-from-tf.sh` — count it,
  don't recall it (three different counts have been asserted; **ten** is correct).
- **The pipeline stage lists vs `grep -nE "^\s*stage\(" Jenkinsfile-ci Jenkinsfile-cd`.** Three
  places narrate the stages in order — `README.submission.md`'s Task 4 section, `docs/cicd.md`, and
  the Pipeline Flow diagram in `docs/eks/architecture.md` — and a *pass on one concern inserts a stage
  into a pipeline owned by another*, which is how all three came to omit `Observability Validation`
  and `Monitoring Gate` after the 2026-08-18 observability work (found 2026-08-20). The Task 4
  section is the one that matters most: it is graded standalone and says its list is read "in order
  (from `Jenkinsfile-ci`)", which invites exactly that diff.
- **The test count.** Asserted in `README.submission.md`, `docs/cicd.md` and the Pipeline Flow
  diagram; it moves whenever a test is added, and on 2026-08-20 the three disagreed with each other
  *and* with the run (250 / 280 vs an actual **289** = 241 backend + 48 worker). Read it off the
  latest `application-ci` console log (`N passed` for each service), which is what actually executed.
- **The observability claims are the one set that is now enforced by a test, not by this list.**
  `scripts/tests/test-observability-docs.sh` (in CI, `python` group) fails the build when
  `docs/observability.md` or `docs/runbooks/README.md` drifts from the charts: the alert set, the
  per-chart and total alert counts, the recording-rule count, the dashboard count and per-dashboard
  panel counts, one-runbook-per-alert in both directions, and every `runbook_url` resolving. It also
  fails when **any live document cites a `Voteball*` alert that does not exist** — which is how
  `VoteballDeploymentDegraded` was found on 2026-08-20, still cited in `docs/production-readiness.md`
  and `docs/eks/architecture.md` three days after being renamed to `DeploymentReplicasMismatch` and
  moved to `charts/observability`. **Dated records are deliberately exempt** from that scan
  (`docs/design/*`, `docs/eks/live-cluster-snapshot.md`, `docs/eks/evidence/*`) — those still say the
  old name correctly, and "fixing" them would destroy the record. So: when you change an alert, a
  dashboard or a recording rule, update `docs/observability.md` in the same commit; the build will
  tell you if you didn't, but only for the countable half — it cannot check whether a sentence is
  still true.
- Cost figures (**≈$8.50/day** up / **≈$256/mo** continuous / **≈$0.19/day** torn down) and the EKS version + support deadline (**1.36 / 2027-08-02**) repeat
  across several docs and must agree. Read the pin from `terraform/variables.tf`, never from memory —
  it moved 1.34 → 1.36 on 2026-07-30 and four docs kept asserting 1.34 afterwards. Dated *evidence*
  (`docs/eks/live-cluster-snapshot.md`) and the upgrade history in `docs/maintenance.md` legitimately
  still say 1.34; those are records, not claims about the present. Don't "fix" them.
- **A doc contradicting another doc — or itself — is the reliable tell.** Both 2026-07-26 findings
  were *solved* problems still described as unsolved, which misdirects effort worse than an omission
  does. `docs/eks/live-cluster-snapshot.md` is the model for dated material: it states up front that
  it is frozen evidence and must not be "corrected".

## Key constraints

- Region and domain come from `terraform/voteball.tfvars` (defaults: `il-central-1`, 2 AZs);
  EKS VPC `10.0.0.0/16` (public / private / isolated-DB subnets, single NAT). Kubernetes namespace **`devops-app`** (never `default`).
- Resource name prefix = `cluster_name` (default `voteball`); single environment only — no dev/prod split, no multi-instance mode
  (this is deliberately simpler than the S3App precedent it was bootstrapped from).
- **All** app containers run non-root with `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`,
  and `readOnlyRootFilesystem:true` (+ an `emptyDir` only where a write is truly needed): backend/worker
  at `uid 1000`, frontend at `uid 101` via `nginxinc/nginx-unprivileged` on **:8080** (the old
  `CHOWN`/`SETUID`/`SETGID` exception is gone — the ALB terminates TLS, so nginx needs no privileges).
- **IRSA least privilege:** only the `worker` and `backup` ServiceAccounts carry an AWS role (SNS-publish
  + S3 `snapshots/`, and S3 `backups/` respectively); `frontend`/`backend` carry **none**. Nothing gets
  `cluster-admin`.
- Postgres connections use `sslmode=require` in production (`DB_SSLMODE` env var; tests override to
  `disable`).
- Admin auth is username/password login (`POST /api/admin/login`) issuing a signed, 12-hour token
  verified via `Authorization: Bearer <token>` — single admin account, password hashed with
  `werkzeug.security`, no server-side session store (rotating `ADMIN_SESSION_SECRET` invalidates all
  outstanding tokens).

## Gitignored / generated files

See `.gitignore` — it is the list, and each rule carries its own reason as a comment (why the
`terraform/` blanket rule is forbidden, why `terraform.tfstate*` needs the glob, why the Jenkins
stack's equivalents had to be listed separately). Read it there rather than duplicating it here.

