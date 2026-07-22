# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Voteball is a public poll correlating football fandom with Israeli political-party voting, deployed on
**Amazon EKS**. It was bootstrapped from infra patterns proven in a separate `Rolling AWS Project files`
(S3App) repo but is fully independent — no shared code or state.

**The repo is designed to be forkable**: no AWS account, region or domain is hardcoded anywhere in
code. Identity lives in exactly two places — `terraform/voteball.tfvars` (pre-apply) and
`terraform output` (post-apply) — both read through `scripts/lib/config.sh`. The env-specific fields of
`charts/voteball/values.yaml` are marked `FILLED-BY-SYNC` and written by
`scripts/sync-values-from-tf.sh`. **If you add a hardcoded ARN, bucket, registry or domain anywhere,
that is a bug.**

> **The single-node k3s deployment is RETIRED and its code was removed on 2026-07-20** (the `terraform/`
> stack, the Ansible playbook/roles, and the SSH-based reverse-seed script — all recoverable from git
> history). The live deployment is `terraform/` + `charts/voteball/`, and the app source is in
> `services/{backend,worker,frontend,backup}/`, one Docker build context each.

**Design docs live in `docs/design/`**, one per feature or infrastructure pass — the balloting and
admin features, then the EKS migration, then the deployment-hardening and repo-forkability passes, then
the 2026-07-20 CI migration from GitHub Actions to Jenkins (`2026-07-20-jenkins-migration-design.md`,
whose G1–G7 labels the `Jenkinsfile` and `docs/cicd.md` both cite), then the 2026-07-21
religion-and-state axis (`2026-07-21-religiosity-axis-design.md`, which extends the party-
categorization doc rather than replacing it).
**Read the relevant one before making architectural changes:** most decisions (and the bugs they
avoid) are explained there, not in code comments — `schema.sql` cites three of them directly to
justify its shape. Several also carry a "Verification outcome" section recording what actually broke
when the design met reality.

*(Write new design docs here as `YYYY-MM-DD-<topic>-design.md`. The step-by-step implementation plans
that accompanied them were process artifacts and were deleted on 2026-07-20 once executed; they are in
git history if you need them.)*

Submission/reference docs: `README.submission.md`, `docs/security.md`, `docs/eks/architecture.md`,
`docs/deploy.md` (plain-language runbook), `docs/eks/live-cluster-snapshot.md`.

## Workflow

**Commit and push changes as you make them in this repo** — this is standing,
pre-authorized permission (per the user's explicit request); don't leave work
committed-but-unpushed or uncommitted waiting to be asked. Still use judgment
on grouping related changes into one coherent commit rather than pushing
every single edit separately, and never force-push.

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
rollups for national totals would over-count a multi-team ballot) that the backend reads for fast
`/api/results` responses.

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

| Route | Method | Auth | Notes |
|---|---|---|---|
| `/health` | GET | none | liveness/readiness probe target |
| `/api/options` | GET | none | leagues/clubs/previous_parties/upcoming_parties, consumed by both frontend pages |
| `/api/vote` | POST | none, cookie-deduped | body `{"team_picks": [{"league_id", "club_id"}, ...], "previous_vote_status", "previous_party_id", "upcoming_vote_status", "upcoming_party_ids"}`; `team_picks` needs ≥1 entry, ≤3 non-null `club_id` picks per distinct `league_id`, and a `club_id: null` ("just this league") entry can't coexist with specific-club entries in the same league; each `club_id`/`league_id` pair is validated against that club's real `{league_id, domestic_league_id}`; sets `voteball_token` cookie (1yr); 409 on repeat vote; 400 if `upcoming_vote_status=considering` with no `upcoming_party_ids`, or if `upcoming_party_ids` has more than 3 entries — client also validates all of this before submitting |
| `/api/results` | GET | none | `?by=club\|league&id=N`, `?by=party&type=previous\|upcoming&id=N` (also returns a national `crosstab` of the other party type), or `?by=all` (national totals); reads the worker-computed rollup tables — `by=league` and `by=all` read the dedup/national-scoped rows so a multi-team ballot isn't over-counted |
| `/api/results/segment` | GET | none | `?previous_party_id=P[&club_id=C\|&league_id=L]`; the "voters like you" migration cut — club/league-scoped if given, else national; returns `{"upcoming": [...], "total": N}` |
| `/api/admin/login` | POST | none | body `{"username", "password"}`; returns `{"token"}` on success, `401` on any failure |
| `/api/admin/previous-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/previous-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/previous-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; moves every vote's `previous_party_id` from `<id>` to `target_id`, returns `{"reassigned": N}` |
| `/api/admin/upcoming-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/upcoming-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/upcoming-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/upcoming-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; reassigns every vote's `<id>` pick to `target_id` (collision-safe against the ≤3-pick cap), returns `{"reassigned": N}` |
| `/api/admin/votes` | GET | Bearer token | list all votes (no `cookie_token` in the response); each vote carries `team_picks: [{"league_id", "club_id"}, ...]` (assembled from separate queries against `vote_clubs`/`vote_leagues`, not a joined `array_agg`, to avoid cartesian-inflating `upcoming_party_ids` alongside it) |
| `/api/admin/votes/<id>` | DELETE | Bearer token | remove one vote; cascades to its `vote_clubs`/`vote_leagues`/`vote_upcoming_parties` rows |

Frontend pages: `index.html`/`vote.js` (voting form, posts to `/api/vote`), `results.html`/`results.js`
(dashboard, reads `/api/results`), `admin.html`/`admin.js` (unlinked from the public pages — party
CRUD, vote reassignment for merges/splits, and votes list/delete, gated by username/password login
issuing a session-stored Bearer token). All three render backend-derived names via
`createElement`/`textContent`, never `innerHTML` string interpolation — `previous_parties`/
`upcoming_parties` names come from an external API and admin input respectively, neither is safe to
trust as pre-escaped HTML.

## Deployment

**`docs/deploy.md` is the plain-language runbook** — follow it for real deploys. Summary of the split:

- **Terraform (`terraform/`)** builds everything AWS: dedicated VPC, EKS cluster + Spot node group,
  OIDC/IRSA roles, ECR, ACM, S3, SNS, Secrets Manager (container only), RDS (restored from a pinned
  snapshot), **and every platform add-on** via `helm_release`/`aws_eks_addon` (AWS Load Balancer
  Controller, External Secrets Operator, Cluster Autoscaler, Node Termination Handler, CloudWatch
  Container Insights, metrics-server, external-dns, ArgoCD, kube-prometheus-stack). Needs
  `terraform/voteball.tfvars` (gitignored) and `-var-file=voteball.tfvars`.
- **Helm (`charts/voteball`)** is the app itself (namespace `devops-app`): 3 Deployments, Services,
  Ingress→ALB, ConfigMap, ExternalSecret, 4 ServiceAccounts, NetworkPolicies, HPA, PDBs, backup CronJob.
  **ArgoCD** syncs it from `master` (GitOps) — the chart is the single authoring path.
- **`./scripts/deploy.sh` / `./scripts/destroy.sh`** run the full ordered sequence (both stop for
  confirmation before Terraform touches billed resources; `VOTEBALL_AUTO_APPROVE=1` skips the prompt
  for unattended runs only). **`VOTEBALL_AUTO_APPROVE=1` alone does NOT make `deploy.sh`
  unattended** — the admin password is prompted on `/dev/tty`, so a detached run also needs
  `ADMIN_PASSWORD` in the environment (the db password is read from `voteball.tfvars` and only needs
  to be passed as `DB_PASS` if it isn't there). Both are collected in a preflight check at the top of
  the script — *before* step 2 — because the failure otherwise lands *after* a ~15-minute billed
  `terraform apply` (hit for real on the 2026-07-21 rebuild). Note `deploy.sh` is only re-runnable at
  a cost: step 3 runs unconditionally and reissues `ADMIN_SESSION_SECRET`, invalidating live admin
  sessions.
- **`./scripts/sync-values-from-tf.sh` owns ten fields in `values.yaml`** — `image.registry`,
  `image.tag`, `config.DB_HOST`, `config.S3_BUCKET`, `config.SNS_TOPIC`, `ingress.host`,
  `ingress.certificateArn`, `ingress.wafAclArn`, `backup.roleArn`, `worker.roleArn`. The committed file carries
  `FILLED-BY-SYNC` placeholders. **Never hand-edit them** — they change on every rebuild. `--check`
  fails on drift *and* verifies `image.tag` names an image that exists in ECR. Its only test is
  `scripts/tests/test-sync-values.sh` (runs offline via `SYNC_STUB_*` env vars); **extend it whenever
  you add a managed field** — it is what catches the `backup.roleArn`/`worker.roleArn` cross-assignment
  that a naive `sed` would cause.
- **Secrets:** `./scripts/seed-eks-secret.sh` takes `ADMIN_USERNAME`/`ADMIN_PASSWORD` from the
  environment or a silent prompt and writes them to Secrets Manager; nothing secret enters git or
  tfstate. `DB_PASS` **must** match `db_password` in `terraform/voteball.tfvars` — so it now defaults
  to reading it straight from there (`tf_db_password` in `scripts/lib/config.sh`), which makes the
  match automatic; pass `DB_PASS` in the environment only to override.
- **CI/CD is Jenkins**, defined by the root `Jenkinsfile` and running on a dedicated EC2 host built by
  the **separate** `terraform/jenkins/` stack. Pushing app code to `master` fires a GitHub webhook →
  guard → build → Trivy → ECR → bump `image.tag` `[skip ci]` → ArgoCD auto-syncs.
  `./scripts/build-push-ecr.sh` does the same by hand. Jenkins authenticates to AWS via an **instance
  profile** (ECR push only — no keys stored anywhere, no EKS/RDS/S3/SNS/Secrets Manager access) and
  **never deploys**; ArgoCD does. Region and cluster name come from Jenkins **global environment
  variables** (`AWS_REGION`, `CLUSTER_NAME`) — the equivalent of the retired repo variables, and the
  reason a hardcoded region or prefix in the `Jenkinsfile` would be a bug. **See `docs/cicd.md`** for
  the full flow, the first-time setup runbook, and failure modes.

**Do not remove the Guard stage from the `Jenkinsfile`, or `scripts/ci/should-skip-build.sh`.** Jenkins
has no native `[skip ci]` — that is a GitHub Actions feature. The Guard stage is the *only* thing
stopping the pipeline's own tag-bump commit from retriggering the pipeline, forever: an unbounded,
billable build loop that also rolls production pods continuously. It looks like dead weight next to the
`[skip ci]` marker in the commit message; it is not. This is proven, not theoretical — build 5 in
`docs/cicd.md` is the webhook firing on Jenkins' own commit and being stopped by exactly this stage.

**`terraform/jenkins/` is a separate stack with its own state and is deliberately outside
`scripts/destroy.sh`'s scope.** Never add it there. A CI server owned by the stack it builds for would be
destroyed — with its credentials, job configuration and build history — on every rebuild cycle. It also
holds no reference to the main stack (its ECR permission is an ARN *pattern*), so it applies cleanly
while the cluster is destroyed. Stop the instance to save money; do not destroy it.

**Do not run `terraform apply` in `terraform/jenkins/` without reading the plan first.**
`data.aws_ssm_parameter.al2023` resolves to the *newest* Amazon Linux 2023 image and `ami` forces
replacement, so once Amazon ships a new image the stack plans a **destroy-and-rebuild of the CI
host** — losing its plugins, credentials, job config and build history. `delete_on_termination =
false` preserves the volume but the replacement instance does not attach it. Confirmed live on
2026-07-21. Fix belongs with the JCasC pass (`docs/production-readiness.md` §7); pinning the AMI is
the stopgap.

**The Jenkins host is configured by JCasC, not by clicking.** `terraform/jenkins/casc/jenkins.yaml`
is applied at every Jenkins start (plugins, admin user, authorization, global env vars, both
credentials, the `voteball` job), so **UI changes are lost on the next restart** — edit the YAML,
commit, and re-run the bootstrap on the host. Secrets come from Secrets Manager (`voteball/jenkins`,
seeded by `./scripts/seed-jenkins-secret.sh`) and are written as one file per value, because the
deploy key is multi-line and its trailing newline is load-bearing. **The GitHub plugin is configured
by XML, not JCasC** (`GitHubPluginConfig` is not data-bound on github 1.47.0 — JCasC aborts the whole
boot on `manageHooks`), and `user_data.sh` writes **two files**, which is not optional:

- **`github-plugin-configuration.xml`** — where the hook secret is actually read from. Uses the
  **plural, populated** `hookSecretConfigs` list with `signatureAlgorithm SHA256`.
- `org.jenkinsci.plugins.github.config.GitHubPluginConfig.xml` — where `manageHooks: false` is read.

Writing only the second produces a host that looks configured and **enforces no webhook signature at
all** (unsigned deliveries accepted with 200). The legacy *singular* `hookSecretConfig` is **not read
on a fresh boot** — it appeared to work only because an already-configured host had the right value
in the other file. `docs/cicd.md` failure mode 3 concerns an *empty* plural list; the fix is to
populate that list, not to avoid it. Test with **SHA-256** — a SHA-1-only probe fails against a
correct config. Likewise don't add `crumbIssuer` back.

**Terraform state lives in S3** (`<cluster_name>-tfstate-<account_id>`), one bucket, one key per
stack (`voteball/main.tfstate`, `voteball/jenkins.tfstate`), with versioning and S3-native locking
(`use_lockfile` — *not* a DynamoDB table; that argument is deprecated, and `required_version` is
`>= 1.11.0` for this reason). **The bucket belongs to no stack and must never be added to
`scripts/destroy.sh`** — same reasoning as `terraform/jenkins/` above, one level more severe: it
would delete the record of what it is deleting, mid-teardown. `backend.hcl` is **generated by
`./scripts/bootstrap-tf-backend.sh` and gitignored**, because a `backend` block cannot interpolate
variables and the bucket name embeds the AWS account id — so `terraform init` needs
`-backend-config=backend.hcl`, and without it fails on incomplete backend configuration rather than
silently using local state. See `docs/design/2026-07-21-terraform-remote-state-design.md`.

**Teardown order matters** and `./scripts/destroy.sh` encodes it: delete the ArgoCD Application (else
`selfHeal` recreates what you remove), then the Ingress (so the ALB de-provisions and external-dns
removes its records — a leftover ALB's ENIs block VPC deletion), wait for the ALB to disappear, *then*
`terraform destroy`. If destroy hangs uninstalling a `helm_release` ("context deadline exceeded" — Helm
can't cleanly uninstall while the cluster is being deleted), `terraform state rm` that release and
re-run destroy; it dies with the cluster anyway.

RDS takes a **final snapshot on destroy** (since 2026-07-20), so destroy→rebuild preserves votes;
`find-latest-snapshot.sh` picks the newest one up automatically before the next apply.

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

### Party ideology axes, and how to revise them in `seed.sql`

Both party tables carry three numeric axes — `economic`, `security` and `religiosity` (each −3..+3,
**nullable**) — plus categorical `bloc`/`sector` and free-text `tags`. See
`docs/design/2026-07-16-party-categorization-analytics-design.md` and
`docs/design/2026-07-21-religiosity-axis-design.md`. Nullable is load-bearing: a `0` asserts a
confirmed centrist position, so a party with no stated position must be `NULL` — `religiosity` is
scoped to *Jewish* religion-and-state, so Ra'am and Hadash are NULL on it. **Balad is not**: its
program demands "complete separation of religion from the state" in as many words, so it scores −3
(seed revision 4 amended the axis design doc's Decision 3 from a category exclusion to a per-party
evidence test — "Arab party" is not itself a reason to leave the axis NULL). Where a party's rhetoric and
record diverge, the number records the **revealed** position and a tag carries the gap
(`claims-economically-liberal`, `instrumentally-clerical`) — do not add claimed/actual column pairs.

**Revising a classification means APPENDING a new unguarded block, never editing the old one.** The
original classification `UPDATE`s end in `AND bloc IS NULL` so a fresh seed is idempotent — which
also means editing them in place changes **nothing on an already-seeded database**, and production
is always already seeded. Revisions therefore append a dated, unguarded block; the last one to
touch a party wins, so the file reads as a revision log. Unguarded is safe because nothing in the
app writes these columns (the admin party endpoints only rename). Verify a revision the way the
existing ones were: seed a container with the *previous* file, apply the new one, confirm the value
actually moves.

**Adding a new axis? Update `services/backend/tests/test_migration.py` too.** It is the reference
test that round-trips the ideology columns and asserts the `CHECK` bounds. The religiosity pass
missed it entirely and shipped an untested constraint; only the final review caught it.

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
(**1.34 leaves standard support 2026-12-02**; see `docs/maintenance.md`)
(`aws eks describe-cluster-versions --region <your region>`). Community chart/add-on versions drift fast;
verify with `helm search repo <chart> --versions` before pinning.

### Jenkins build host (`terraform/jenkins/` — a SEPARATE stack)

```bash
cd terraform/jenkins
terraform apply -var-file=jenkins.tfvars   # own state; never destroyed by scripts/destroy.sh
terraform output -raw ssh_tunnel_command   # then browse http://localhost:8080
```

Normally left **stopped** (~$6/mo vs ~$37 running; the Elastic IP is billed either way):
`aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"`. **Webhooks are
silently discarded while it is stopped.** `admin_cidr` is your home IP — update and re-apply when
your ISP reassigns it. See `terraform/jenkins/README.md`.

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

### Backend (`services/backend/`)

**Adding a new backend or worker source file: update that service's `Dockerfile` `COPY` line.** On EKS
the build context *is* the source directory (`scripts/build-push-ecr.sh` / the CI workflow run
`docker build` against it), so the Dockerfile's explicit `COPY` list is the only place that can drop a
file — and a file missing there is simply absent from the image (no build error for the *app* files,
just an `ImportError`/404 at runtime). Same class of gap as the frontend note below.

Tests run TDD-style against a **real** Postgres, not mocks. Note the `.venv`s are **not relocatable** —
if a service directory is ever moved, delete and recreate them, or every command fails with a confusing
`ModuleNotFoundError` naming the *old* path (absolute paths are baked into the shebangs and
`pyvenv.cfg`):

```bash
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd services/backend
python -m venv .venv && source .venv/bin/activate   # or use uv if pip is unavailable
pip install -r requirements.txt
python -m pytest tests/ -v                          # full suite
python -m pytest tests/test_app.py::test_health -v   # single test
```

`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_USERNAME`,
`ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET`, etc.) via
`setdefault` and its `conn` fixture drops and recreates every table before each test (see the
`DROP TABLE ... CASCADE` list — keep it in sync with `schema.sql` when adding tables).

### Worker (`services/worker/`)

Same real-Postgres TDD pattern as the backend; reuse the `voteball-test-db` container. The worker's
tests need `schema.sql` (owned by the backend) loaded into that database, since the worker itself
never creates schema.

### Frontend (`services/frontend/`)

Plain HTML/CSS/vanilla JS, no build step, no automated test suite (matches the S3App precedent) —
verify by driving the real page in a browser (or during Task 21-style end-to-end deploy verification).

**Adding a new frontend file (JS/CSS/HTML) requires updating `services/frontend/Dockerfile`'s `COPY`
line too** — the `Dockerfile` lists every file it bakes into the image by name, not by directory. A file
that exists on disk but is missing from that `COPY` line 404s at runtime with no build error and
no obvious symptom beyond "the page is broken" (any script that calls a function the missing file
was supposed to define throws and silently kills the rest of that script's execution) — this
exact gap shipped once (i18n.js, fixed in commit `d02e255`) before being caught.

**`services/frontend/logos/` is the exception: it is copied as a whole directory**, so adding a club
crest is a data change, not a Dockerfile edit. Put crests there for clubs with no Wikimedia artwork and
point `seed.sql`'s `logo_url` at `/logos/<file>.png`. **Do not hotlink social-media CDNs** — those URLs
are signed and expire, the CDN may refuse hotlinks, and (the one that actually bit, on F.C. Kiryat Yam)
tracker blockers drop `*.fbcdn.net` in the browser, so the crest is invisible to many visitors while
`curl` fetches it happily. That class of bug is undetectable server-side.

### Helm chart (`charts/voteball/`)

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
the `allow-app-egress` NetworkPolicy so it can still reach RDS through the default-deny.

**Alert rules must carry `release: kube-prometheus-stack`.** Without that label the PrometheusRule is
created, looks correct in `kubectl get prometheusrules`, and is silently never evaluated. Only write
rules against metrics this cluster actually exposes (kube-state-metrics): RDS, ALB and ACM figures are
CloudWatch-only and nothing scrapes them into Prometheus, so such rules could never fire — worse than no
rule, because the coverage looks complete.

ArgoCD owns this release in the cluster (`argocd/voteball-application.yaml`), so **changes reach the
cluster by committing to `master`**, not by running `helm upgrade` by hand. If you do install manually,
note ArgoCD's `selfHeal` will fight you — concretely, a manual `helm upgrade` now fails with
`conflict with "argocd-controller"` on server-side-apply field ownership. Upgrades go through git.

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

Gitignored — either real secrets or machine-specific/generated output:
`terraform/voteball.tfvars`, `terraform/terraform.tfstate*`, and the Jenkins stack's equivalents
(`terraform/jenkins/jenkins.tfvars`, `terraform/jenkins/terraform.tfstate*`, `terraform/jenkins/.terraform/`
— the existing rules are anchored to the stack root and do **not** match the subdirectory, so they had to
be listed separately)
(the `*` glob matters — Terraform writes *timestamped* backups like `terraform.tfstate.1784477786.backup`
that a bare `.backup` pattern misses), `*.tfplan`/`tfplan`, `*.pem`, `*.pdf` (course reference material),
`.remember/`, `.claude/settings.local.json`, and `EXPLAINER.md`/`PROJECT-QA.md` (personal notes).

