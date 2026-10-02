# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Voteball is a public poll correlating football fandom with Israeli political-party voting, deployed on
**Amazon EKS**. It was bootstrapped from infra patterns proven in a separate `Rolling AWS Project files`
(S3App) repo but is fully independent — no shared code or state.

**The repo is designed to be forkable**: no AWS account, region or domain is hardcoded anywhere in
code. Identity lives in exactly two places — `terraform/voteball.tfvars` (pre-apply) and
`terraform output` (post-apply) — both read through `scripts/lib/config.sh`. The nine
environment-identity fields the chart needs are injected by the ArgoCD Application's
`helm.parameters` (next paragraph); `scripts/sync-values-from-tf.sh` writes only `image.tag`. **If you
add a hardcoded ARN, bucket, registry or domain anywhere, that is a bug.**

**Until 2026-09-08 `charts/voteball/values.yaml` was a deliberate exception carrying REAL values, and
it no longer is.** Nine environment-identity fields — `image.registry`, `config.DB_HOST/S3_BUCKET/
SNS_TOPIC`, `ingress.host/certificateArn/wafAclArn` and both `roleArn`s — moved into the **ArgoCD
Application's `helm.parameters`**, which `scripts/render-argocd-app.sh` renders from Terraform
outputs and `kubectl apply`s: the template is in git, the values never are. This is a **public**
repo, and those fields published the AWS account id seven times plus the RDS endpoint and four ARNs.
`image.tag` and `image.digests` deliberately STAY committed — `scripts/ci/previous-tag.sh` recovers
the rollback target with `git log -p` over that file, so its history *is* the rollback mechanism, and
a git SHA leaks nothing. `sync-values-from-tf.sh` therefore manages **one** field, not ten. See
`docs/design/2026-09-08-argocd-helm-parameters-design.md`. The paragraph below is the pre-2026-09-08
rationale, kept because the failure it describes is still what happens if the Application is applied
WITHOUT rendering:

**The former exception, and why it existed.**
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

Submission/reference docs: `docs/security.md`, `docs/eks/architecture.md`,
`docs/deploy.md` (plain-language runbook), `docs/cicd.md` (CI/CD operational reference),
`docs/observability.md` (monitoring operational reference — Prometheus/Grafana/Alertmanager,
CloudWatch, the SLIs, every alert and its runbook, the two pipeline gates),
`docs/eks/live-cluster-snapshot.md`,
`docs/party-classifications.md` (why each party carries the ideology values it does — the reasoning
that used to live in `seed.sql` comments).

**`docs/eks/evidence/` is GONE (deleted 2026-09-09) and must not come back.** It held 110 raw
`kubectl`/`terraform`/Jenkins captures, 4.6 MB, produced by four `scripts/capture-*` scripts that were
deleted with it — the project is no longer submitted anywhere, so nothing consumed them. Two
consequences worth knowing before you "restore the evidence for a claim":

- **The captures were unedited on purpose, and that is why they carried ~1,400 occurrences of the AWS
  account id** — far more than the seven in `values.yaml` that the 2026-09-08 helm.parameters pass was
  written to remove. Deleting them un-published nothing (git history is permanent, an account id
  cannot be rotated); it stops the pile growing. `docs/security.md`'s "What is deliberately public"
  section carries the full reasoning **plus a measured 2026-09-09 check** that the id is inert — no
  publicly shared EBS snapshot, AMI, RDS snapshot, bucket or ECR repository in the account. Re-run
  that check after anything that shares a snapshot or an image; do not re-argue it from first
  principles.
- **The chaos drills survive and are the durable half.** `scripts/drills/drill-{1,3,4,5}-*.sh` still
  run and still write transcripts — to a gitignored `drill-output/` (`DRILL_OUT_DIR` overrides), never
  into the repo. A re-runnable drill outlives a transcript: the August set expired precisely because
  it was a sequence of commands somebody remembered, and the transcripts proved nothing once the
  commands were lost. Cite the script, not a capture.

Live docs therefore state drill outcomes as prose with no link. That is deliberate — **a link that
404s is worse than a sentence that stands on its own**, and it is the same reasoning that deleted
`README.submission.md` rather than leaving it stale.

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

### Notes that moved next to the code (2026-10-02)

The rest of what used to be in this section loads automatically when you work in the directory it
describes:

- Backend request handling (`try/finally` around `get_db()`, `require_admin`), `connect_timeout` →
  `services/backend/CLAUDE.md`
- Languages (English/Hebrew/Russian: the `DICTIONARY`, the `name_*` columns, Cyrillic homoglyphs,
  fonts) → `services/frontend/CLAUDE.md`
- The synthetic canary and why every ratio SLI depends on it → `charts/voteball/CLAUDE.md`
- Jenkins' two Prometheus metric families → `charts/observability/CLAUDE.md`

## Deployment

**`docs/deploy.md` is the plain-language runbook** — follow it for real deploys. Summary of the split:

- **Terraform (`terraform/`)** builds everything AWS: dedicated VPC, EKS cluster + Spot node group,
  OIDC/IRSA roles, ECR, ACM, S3, SNS, Secrets Manager (container only), RDS (restored from a pinned
  snapshot), **and every platform add-on** via `helm_release`/`aws_eks_addon` (AWS Load Balancer
  Controller, External Secrets Operator, Cluster Autoscaler, Node Termination Handler, CloudWatch
  pod logging, metrics-server, external-dns, ArgoCD, kube-prometheus-stack, and the ECK operator).
  Needs `terraform/voteball.tfvars` (gitignored) and `-var-file=voteball.tfvars`.
- **Helm (`charts/voteball`)** is the app itself (namespace `devops-app`): 3 Deployments, Services,
  Ingress→ALB, ConfigMap, ExternalSecret, 4 ServiceAccounts, NetworkPolicies, HPA, PDBs, backup CronJob.
  **ArgoCD** syncs it from the **`release`** branch (GitOps) — the chart is the single authoring path.
  `release` is written only by `application-cd`; pushing to `master` cannot reach the cluster.
- **Helm (`charts/observability`, `charts/logging`)** are the second and third ArgoCD Applications
  (dashboards and alerts as code; EFK logging), each with its own `AppProject`, synced from `release`
  the same way. Read `charts/observability/CLAUDE.md` / `charts/logging/CLAUDE.md` before touching either.
- **Jenkins** (namespace `ci`, pipelines `application-ci` and `application-cd`) is a Terraform-owned
  platform add-on, not part of the app chart. Invoke the **`voteball-cicd` skill** before editing
  either `Jenkinsfile-*`, `ci/jenkins/*` or `terraform/addon-jenkins.tf`.

### Rules that hold from anywhere (the reasoning lives next to the code)

Until 2026-10-02 this section was ~700 lines of deploy, teardown and CI detail loaded into every
session. It now lives in the files named below, which load when you work in that directory. **Each
line here is the prohibition only — read the file it names before acting on that area.** Code
comments that cite "the root CLAUDE.md" or "CLAUDE.md's teardown section" mean these files.

Money and irreversibility:

- **`terraform apply` creates billed resources (≈$8.50/day up). Confirm before running; never
  automatic.** A module or provider upgrade is not done until a **from-scratch** deploy has passed.
  → `terraform/CLAUDE.md`
- **The Terraform state bucket belongs to no stack and must never be added to `scripts/destroy.sh`.**
  → `terraform/CLAUDE.md`
- **Do not add `ignore_changes` to `final_snapshot_identifier`** (`terraform/modules/database/main.tf`)
  — it silently disables the final snapshot and wedges the VPC teardown. → `terraform/CLAUDE.md`
- **Tear down with `./scripts/destroy.sh`, never a bare `terraform destroy`** — the order (Applications,
  all three Ingresses, six Helm releases, ECK operator last, External Secrets last of all) is
  load-bearing. The S3 `pg_dump`s do not survive teardown; the final snapshot does, and is verified by
  `SnapshotCreateTime`, never by name. → `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`
- **Re-running `deploy.sh` rewrites the admin secret every run** (password, username back to `admin`,
  all sessions invalidated). → `scripts/CLAUDE.md`

Things that look removable and are not:

- **Never remove `connect_timeout=5` from `db.get_db()`** (backend and worker). → `services/backend/CLAUDE.md`
- **Never disable the canary Deployment** — it is the denominator of every availability SLI.
  → `charts/voteball/CLAUDE.md`
- **Do not remove the Guard stage from `Jenkinsfile-ci` or `scripts/ci/should-skip-build.sh`, and do
  not reintroduce a raw `changeset` directive.** → `voteball-cicd` skill
- **Do not "tidy" the `buildkit` container's `allowPrivilegeEscalation: true`**, and keep both ECR
  cache repos `MUTABLE` and outside `local.ecr_repos`. → `voteball-cicd` skill
- **`charts/logging` ships `enabled: true`; keep `action.auto_create_index` and the `checksum/config`
  annotation.** → `charts/logging/CLAUDE.md`

How changes reach the cluster:

- **A chart resource that references a Terraform-created object must be gated off by default AND have
  a seeding step in `deploy.sh`.** → `charts/voteball/CLAUDE.md`
- **Nothing is configured through the ArgoCD or Jenkins UI**, and a Jenkins/JCasC change does nothing
  until `terraform apply`. → `terraform/CLAUDE.md`, `voteball-cicd` skill
- **Read the `release` branch by content (`git show origin/release:<path>`), never by ancestry.**
  → `scripts/CLAUDE.md`
- **Secrets live in AWS Secrets Manager; no secret value enters git or tfstate.** → `scripts/CLAUDE.md`,
  `docs/security.md`

Writing scripts and checks:

- **Never pipe `terraform apply`/`destroy` through anything** (`| tail` reports `tail`'s exit status),
  and under `pipefail` never `producer | grep -q`. → `scripts/CLAUDE.md`
- **Never introduce a bare `GITHUB_TOKEN` into any script's environment.** → `scripts/CLAUDE.md`
- **Every script that calls `aws` needs `export AWS_PAGER=""`** (via `scripts/lib/config.sh`), or it
  hangs at a terminal. → `scripts/CLAUDE.md`
- **Unattended runs call `refresh-api-cidr.sh --ensure`, never the plain form.** `watch-aws-progress.sh`
  stays read-only and never exits non-zero. → `scripts/CLAUDE.md`
- **Never put a runtime-fetched secret in an argument position inside a Jenkins `sh` step** (`set -x`
  prints it). → `voteball-cicd` skill
- **Extend the matching `scripts/tests/` test whenever you change a script**, and prove a check can
  fail before trusting it to pass. → `scripts/CLAUDE.md`

## Party ideology axes (`seed.sql`)

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
  `seed.sql` is now **679 lines / 47 statements** (from 1,276 lines / 78 statements), with **zero**
  patch statements — verify with `grep -c ';\s*$' services/backend/seed.sql` rather than trusting
  this number, it will drift the next time the file changes.
- **Restructuring `seed.sql` must be proven data-neutral, now via
  `scripts/seed/verify-neutrality.sh <production-dump.sql> <old-git-ref>`** — it builds three
  databases (an old-seeded baseline, the same dump migrated through the new files, and a fresh
  install) and diffs them, excluding timestamps and keying rows by their natural name column rather
  than sorting whole-row text. The old-seeded-vs-migrated diff is the one that matters — it is the
  only one built from the same production dump on both sides, so it is the only one that proves an
  *already-seeded* database (the only kind that exists in production) ends up where it started.

## Per-directory guidance (loads automatically when you work there)

The build, test and gotcha notes for each component now live next to the code, in a `CLAUDE.md` that
loads only when Claude is working under that directory:

| File | Covers |
|---|---|
| `services/backend/CLAUDE.md` | `seed.sql` ideology-axis revision, the real-Postgres test setup, `requirements.txt` vs `requirements-dev.txt`, the Dockerfile `COPY` rule |
| `services/worker/CLAUDE.md` | why the worker duplicates `db.py`, its test setup, the Dockerfile `COPY` rule |
| `services/frontend/CLAUDE.md` | the Dockerfile `COPY`-by-name rule, `logos/` as the directory exception, the no-hotlinking rule |
| `charts/voteball/CLAUDE.md` | `helm lint`/`template`, the migration Job's `post-install,pre-upgrade` split, the `release: kube-prometheus-stack` alert-rule label |
| `terraform/CLAUDE.md` | commands, cost and version pins, the upgrade "two contracts" rule, state in S3, the final-snapshot trap, the CloudWatch add-on's cost, ArgoCD's two config files |
| `scripts/CLAUDE.md` | `deploy.sh`/`destroy.sh` ordering, secrets seeding, the whole teardown procedure, swallowed-exit-status and silent-name-contract defects, the AWS pager guard, `watch-aws-progress.sh`, `scripts/ci/` and the script test suite |
| `charts/logging/CLAUDE.md` | the ECK operator, Kibana content import, the Fluentd parser, the `auto_create_index` deadlock, EFK teardown order |
| `charts/observability/CLAUDE.md` | what the chart owns vs Terraform, the Jenkins ServiceMonitor gate, Jenkins' two metric families |
| `.claude/skills/voteball-cicd/SKILL.md` (a skill, invoked rather than auto-loaded — the `Jenkinsfile-*` sit at the repo root) | both pipelines, the Guard stage, JCasC, BuildKit, build caches, `JENKINS_HOME` on EFS |

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

## Doc claims that drift (check these before trusting them)

Two audit passes on 2026-07-26 found seven stale claims; every one was mechanically checkable.

- **The API surface table** (now `.claude/skills/voteball-api/SKILL.md`) vs
  `grep -oE "@app\.route\('[^']+'" services/backend/app.py` — 10 routes (the whole clubs/leagues
  admin block) were undocumented until that audit.
- `docs/deploy.md`'s numbered steps vs `grep -E '^\s*step "' scripts/deploy.sh`.
- The sync-managed field list vs the `managed` dict in `scripts/sync-values-from-tf.sh` — count it,
  don't recall it (it was **ten** until 2026-09-08 and is **one** since; this very line still
  said "ten is correct" until 2026-10-02).
- **The pipeline stage lists vs `grep -nE "^\s*stage\(" Jenkinsfile-ci Jenkinsfile-cd`.** Two
  places narrate the stages in order — `docs/cicd.md` and the Pipeline Flow diagram in
  `docs/eks/architecture.md` — and a *pass on one concern inserts a stage into a pipeline owned by
  another*, which is how they (and `README.submission.md`'s Task 4 section, deleted 2026-09-09) came
  to omit `Observability Validation` and `Monitoring Gate` after the 2026-08-18 observability work
  (found 2026-08-20). Deleting the third copy removed the worst offender, not the trap: two lists
  read "in order (from `Jenkinsfile-ci`)" still invite exactly that diff.
- **The test count.** Asserted in `docs/cicd.md` and the Pipeline Flow diagram; it moves whenever a
  test is added, and on 2026-08-20 those two and `README.submission.md` disagreed with each other
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
  (`docs/design/*`, `docs/eks/live-cluster-snapshot.md`) — those still say the
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
