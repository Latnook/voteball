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
ArgoCD deploys what is on `master`, not what is on your disk, so those ten fields must be committed
with **real** values — this account's ECR registry, RDS endpoint, ACM/WAF/IRSA ARNs and domain are
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
whose G1–G7 labels the `Jenkinsfile` and `docs/cicd.md` both cite), then the 2026-07-21
religion-and-state axis (`2026-07-21-religiosity-axis-design.md`, which extends the party-
categorization doc rather than replacing it), then the 2026-07-31 search-engine-visibility pass
(`2026-07-31-seo-design.md`, which records what was deliberately *not* done — read its scope section
before "improving" the SEO).
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
`docs/deploy.md` (plain-language runbook), `docs/eks/live-cluster-snapshot.md`,
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
`vote_leagues`, `vote_upcoming_parties` — a ballot can name up to 3 clubs per league across any
number of leagues, so `votes` itself carries no league/club column; `vote_clubs` records each
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
replace all fields, so an omitted name is written as `NULL`. `patchClubLeagues` in `admin.js` (the
"add to Champions League" button) is the one call site that does this, and it resends
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
  pod logging, metrics-server, external-dns, ArgoCD, kube-prometheus-stack). Needs
  `terraform/voteball.tfvars` (gitignored) and `-var-file=voteball.tfvars`.

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
  **ArgoCD** syncs it from `master` (GitOps) — the chart is the single authoring path.
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
- **`./scripts/deploy.sh` / `./scripts/destroy.sh`** run the full ordered sequence (both stop for
  confirmation before Terraform touches billed resources; `VOTEBALL_AUTO_APPROVE=1` skips the prompt
  for unattended runs only). **`VOTEBALL_AUTO_APPROVE=1` alone does NOT make `deploy.sh`
  unattended** — the admin password (and, since the in-cluster Jenkins move, a Jenkins username +
  password) is prompted on `/dev/tty`, so a detached run also needs `ADMIN_PASSWORD`,
  `JENKINS_ADMIN_USER` and `JENKINS_ADMIN_PASSWORD` in the environment (the db password is read from
  `voteball.tfvars` and only needs to be passed as `DB_PASS` if it isn't there). All are collected in a
  preflight check at the top of the script — *before* the billed `terraform apply` — because the
  failure otherwise lands *after* a ~15-minute billed run (hit for real on the 2026-07-21 rebuild). Note
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
  carries the **real, current** values, not placeholders — ArgoCD deploys from `master`, so it has to
  (see the forkability note at the top). **Never hand-edit them** — they change on every rebuild. `--check`
  fails on drift *and* verifies `image.tag` names an image that exists in ECR. Its only test is
  `scripts/tests/test-sync-values.sh` (runs offline via `SYNC_STUB_*` env vars); **extend it whenever
  you add a managed field** — it is what catches the `backup.roleArn`/`worker.roleArn` cross-assignment
  that a naive `sed` would cause.
- **Secrets:** `./scripts/seed-eks-secret.sh` takes `ADMIN_USERNAME`/`ADMIN_PASSWORD` from the
  environment or a silent prompt and writes them to Secrets Manager; nothing secret enters git or
  tfstate. `DB_PASS` **must** match `db_password` in `terraform/voteball.tfvars` — so it now defaults
  to reading it straight from there (`tf_db_password` in `scripts/lib/config.sh`), which makes the
  match automatic; pass `DB_PASS` in the environment only to override.
- **CI/CD is Jenkins, running IN the cluster** (namespace `ci`), installed by Terraform as a
  `helm_release` (`terraform/addon-jenkins.tf`) of the official chart, configured by JCasC
  (`ci/jenkins/jenkins.yaml`). Pushing app code to `master` fires a GitHub webhook → guard → build
  (rootless BuildKit, pod agent) → Trivy → ECR → bump `image.tag` `[skip ci]` → ArgoCD auto-syncs.
  `./scripts/build-push-ecr.sh` does the same by hand, and is the **only** way to build while the
  cluster is destroyed (there is no CI without a cluster). Agent pods authenticate to AWS via **IRSA**
  (ECR push only, on the `jenkins-agent` ServiceAccount — the controller itself carries no AWS role at
  all). Region, cluster name, GitHub repo and app domain arrive as **pod environment variables** set by
  Terraform — the equivalent of the retired EC2 host's global environment variables, and the reason a
  hardcoded region or prefix in the `Jenkinsfile` or `ci/jenkins/jenkins.yaml` would be a bug. **See
  `docs/cicd.md`** for the full flow, the first-time setup runbook, and failure modes.

  **Jenkins is a platform add-on, not the application** — the opposite of `charts/voteball`. Changes to
  the Jenkins release reach the cluster by `terraform apply`, **not** by committing to `master` (ArgoCD
  does not manage it; Terraform does, the same way it owns ArgoCD, ESO and external-dns). Committing a
  change to `ci/jenkins/jenkins.yaml` or `terraform/addon-jenkins.tf` and walking away does nothing
  until someone runs `terraform apply`.

  **The controller is disposable — `JENKINS_HOME` is an `emptyDir`, not a volume, and that is
  deliberate.** The node group is 100% Spot, reclaimed roughly once a day; an EBS volume is locked to
  one Availability Zone, so a PersistentVolumeClaim would need every reschedule to land back in the
  same AZ or the pod hangs `Pending` forever — the one failure mode in this design that needs a human.
  At a daily reclaim rate a PVC would preserve almost nothing while adding that risk. **Do not "fix"
  this with a PVC.** What is lost on a reclaim is build history (capped at 20 builds anyway) — the
  durable record is the `ci: image tag <sha> [skip ci]` commits on `master`, which never expire.

  **The `buildkit` container is the one container in this entire project that runs
  `allowPrivilegeEscalation: true` plus `SETUID`/`SETGID`.** Rootless BuildKit builds inside a user
  namespace, and mapping UIDs into that namespace needs those two things — without them the pod looks
  healthy (4/5 containers) and the build just hangs forever with nothing logged. It is still **uid
  1000, not privileged, no host devices, no host paths** — nothing like Docker-in-Docker's
  `privileged: true`, which is why DinD was rejected for this pipeline in the first place. Every
  container in `devops-app` still runs `allowPrivilegeEscalation: false`; **do not "tidy" this one
  container to match them** — rootless BuildKit cannot start without the exception, and it is scoped to
  one CI pod in a namespace whose NetworkPolicy already denies it any route to RDS or `devops-app`.

  **Both build caches live in ECR** (`${cluster_name}-buildcache`, `${cluster_name}-trivy-db`), and
  both repos **must stay `MUTABLE` and outside `local.ecr_repos`** in `terraform/ecr.tf`. That set is
  `IMMUTABLE` because a git-SHA tag must never be silently overwritten; a cache tag is *rewritten on
  every build* by design, so adding either repo to that set fails every build's cache export with
  "cannot overwrite immutable tag" — at the end of a long build, not the start.

**Do not remove the Guard stage from the `Jenkinsfile`, or `scripts/ci/should-skip-build.sh`.** Jenkins
has no native `[skip ci]` — that is a GitHub Actions feature. The Guard stage is the *only* thing
stopping the pipeline's own tag-bump commit from retriggering the pipeline, forever: an unbounded,
billable build loop that also rolls production pods continuously. It looks like dead weight next to the
`[skip ci]` marker in the commit message; it is not. This is proven, not theoretical — build 5 in
`docs/cicd.md` is the webhook firing on Jenkins' own commit and being stopped by exactly this stage.

**Jenkins is configured by JCasC, not by clicking — but the mechanism is `terraform apply`, not a
reboot of a hand-managed host.** `ci/jenkins/jenkins.yaml` is loaded into the Helm release's
`controller.JCasC.configScripts` and applied by the chart's config-reload sidecar (plugins, admin
user, authorization, the Kubernetes cloud, the agent pod template, both credentials, the `voteball`
job), so **UI changes are lost the next time the controller restarts** — which, on Spot, is roughly
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

**Teardown order matters** and `./scripts/destroy.sh` encodes it: delete the ArgoCD Application (else
`selfHeal` recreates what you remove), then **both Ingresses** (so the ALB de-provisions and
external-dns removes its records — a leftover ALB's ENIs block VPC deletion), wait for the ALB to
disappear, *then* `terraform destroy`.

**"Both" is load-bearing.** Since 2026-07-31 `devops-app/voteball` and `ci/jenkins-webhook` share ALB
group `voteball`, and an ALB is de-provisioned only when its group has **no** members left — deleting
one leaves it running. The same change renamed the ALB: a grouped one is `k8s-<group>-<hash>`, not
`k8s-<namespace>-<ingress>-<hash>`, so any check filtering on the old shape reports "ALB gone"
instantly while it is still there. `scripts/cleanup-stale-dns.sh` likewise cleans **two** hosts now,
`<app_domain>` and `jenkins.<app_domain>`.

If destroy hangs uninstalling a `helm_release` ("context deadline exceeded" — Helm can't cleanly
uninstall while the cluster is being deleted), `terraform state rm` that release and re-run destroy;
it dies with the cluster anyway. **There are now three such releases**, not one: the app's, plus
`jenkins` and `jenkins-support`.

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

Two teardown behaviours `destroy.sh` handles that a manual `terraform destroy` does not:
- **`./scripts/cleanup-stale-dns.sh`** removes this cluster's Route53 records if external-dns didn't get
  to it first (it only reconciles on a timer and can be destroyed before noticing the deleted Ingress).
  Gated on the ownership TXT (`external-dns/owner=voteball`), so apex/MX/DKIM records are never eligible.
- **An orphaned-ENI reaper** runs in the background during destroy. The VPC CNI leaves detached
  `aws-K8S-*` interfaces when nodes terminate, and they make Terraform retry `DeleteSubnet` against a
  `DependencyViolation` for 10–20 minutes. See `docs/deploy.md` troubleshooting for the manual command.

**Do not add `ignore_changes` to `final_snapshot_identifier`** in `database.tf` — the provider reads it
from state at destroy time, so that silently disables the final snapshot *and* wedges the VPC teardown.
There's a comment there explaining why; keep it.

### Party ideology axes (`seed.sql`)

Both party tables carry three numeric axes — `economic`, `security`, `religiosity` (each −3..+3,
**nullable**, where `NULL` means "no stated position" and `0` asserts a confirmed centrist one) —
plus categorical `bloc`/`sector` and free-text `tags`. `seed.sql` holds the values;
`docs/party-classifications.md` holds the reasoning; keep them apart.

**The full revision procedure is in `services/backend/CLAUDE.md`**, which loads whenever you work
under that directory — read it before touching `seed.sql`. Three rules from it are repeated here
because getting them wrong destroys data rather than just being wrong:

- **The six ideology `UPDATE`s are deliberately UNGUARDED — do not add `AND bloc IS NULL`.** A guard
  makes every later edit unreachable on an already-seeded production database.
- **The name and `logo_url` blocks stay guarded, for the opposite reason** — admins edit those
  live, and an unguarded write destroys their edits. Do not "make them consistent."
- **Names and logos are one `VALUES` block per table, not one statement per row** (61 statements on
  pod boot, not 209). Adding a logo means adding a *tuple* — and unlike the old one-statement-per-row
  form, a duplicate key no longer resolves by file order, it matches arbitrarily.
- **Restructuring `seed.sql` must be proven data-neutral** (dump every affected table from an
  old-seeded DB, diff against both a fresh new-seeded DB and the old-seeded DB with the new file
  applied on top; exclude `updated_at` and sort by `id`, or the proof fails on artefacts).

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
$200/mo) — treat it as a confirm-before-running step, never automatic. Pins that matter: **`aws ~> 5.0`**
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

### CI guard scripts (`scripts/ci/`)

`should-skip-build.sh` (G2, the `[skip ci]` loop guard) and `images-exist.sh` (G1, the immutable-tag
re-run check) hold the `Jenkinsfile`'s two decision points, extracted so they can be tested without
triggering real builds:

```bash
scripts/tests/test-ci-guards.sh   # offline; stubs ECR via CI_STUB_DESCRIBE_CMD
```

Same offline-stub pattern as `scripts/tests/test-sync-values.sh`. **Extend it whenever you change
either guard** — pipeline logic that can only be tested by running the pipeline is exactly what makes
G2 dangerous. Note the two guards deliberately fail safe in *opposite* directions (skip vs rebuild);
that asymmetry is intentional, don't "make them consistent".

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
- **ArgoCD owns the chart release**, so changes reach the cluster by committing to `master`, not by
  running `helm upgrade` by hand — a manual upgrade now fails on server-side-apply field ownership.

### Doc claims that drift (check these before trusting them)

Two audit passes on 2026-07-26 found seven stale claims; every one was mechanically checkable.

- **The API surface table** (now `.claude/skills/voteball-api/SKILL.md`) vs
  `grep -oE "@app\.route\('[^']+'" services/backend/app.py` — 10 routes (the whole clubs/leagues
  admin block) were undocumented until that audit.
- `docs/deploy.md`'s numbered steps vs `grep -E '^\s*step "' scripts/deploy.sh`.
- The sync-managed field list vs the `managed` dict in `scripts/sync-values-from-tf.sh` — count it,
  don't recall it (three different counts have been asserted; **ten** is correct).
- Cost figures (~$200/mo stack) and the EKS version + support deadline (**1.36 / 2027-08-02**) repeat
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

