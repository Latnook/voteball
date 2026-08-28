# Deploy guide (EKS)

How to put the Voteball site online on AWS, check it works, and take it back down.

**Heads-up:** running this costs real money (**~$8.50/day** while it's up, ~$256/month if left running;
~$0.19/day once destroyed). Always take it down when
you're done. Last verified end-to-end on 2026-07-31 (full destroy + rebuild, with the vote count
unchanged either side — 15 votes, identical ids; raw captures from the 2026-07-27 cycle in
[`docs/eks/evidence/`](eks/evidence/)).

## Contents

**Logging in to something** — passwords are spread across three systems, so start here:

| I want to get into… | Section |
|---|---|
| The **admin page** (`/admin`) | [The website and the admin page](#the-website-and-the-admin-page) |
| **ArgoCD** — and where its password comes from | [ArgoCD](#argocd) |
| **Jenkins** — the build server | [Jenkins (the build server)](#jenkins-the-build-server) |
| **Grafana / Prometheus / Alertmanager** | [Grafana, Prometheus and Alertmanager](#grafana-prometheus-and-alertmanager) |
| The **database** | [The database](#the-database) |
| Changing an admin username or password | [Change the admin username or password](#change-the-admin-username-or-password) |

**Everything else**

- [The two halves of the system (in plain terms)](#the-two-halves-of-the-system-in-plain-terms)
- [One-time setup](#one-time-setup)
- [Put the site online](#put-the-site-online) · [Run it in a real terminal](#run-it-in-a-real-terminal)
- [Check it worked](#check-it-worked)
- [Connect to each part](#connect-to-each-part-dashboards-argocd-jenkins-the-database) ·
  [First: point kubectl at the cluster](#first-point-kubectl-at-the-cluster) ·
  [If a connection won't work](#if-a-connection-wont-work)
- [Take it down (stop paying)](#take-it-down-stop-paying)
- [If something breaks](#if-something-breaks)

---

## The two halves of the system (in plain terms)

- **Terraform** builds the AWS side: the Kubernetes cluster, the database, the container registry, the
  load balancer's certificate, etc. Think of it as *building the ground the app stands on*.
- **Helm** installs the Voteball app *onto* that ground: the website, the backend, the worker.

You run Terraform first, then Helm. Taking it down is the reverse.

*(The old single-server "k3s" setup is retired. This guide is the current EKS one.)*

---

## One-time setup

You need these installed: `terraform`, the `aws` command, `kubectl`, `helm`, `docker`, `python3`,
`openssl`, `jq`, `ssh-keygen` and `gh` (the GitHub CLI). You must be logged into AWS
(`aws sts get-caller-identity` should show your account), logged into GitHub (`gh auth status`, needing
`repo` scope), and you need a **Route53 hosted zone you already own** — the deploy looks it up, it never
creates one.

**AWS CLI v1 and v2 both work, and the scripts handle the one difference between them.** v2 shows
command output in a pager (`less`) when it is printing to a terminal, which would stop a deploy dead
on a normal-looking step — waiting for you to press `q`, and looking exactly like a hung AWS call.
Every script disables that (`AWS_PAGER=""`, set once in `scripts/lib/config.sh`), so you do not have
to configure anything. If you run `aws` commands **by hand** from this guide and one seems to freeze
with a `:` at the bottom of the screen, that is the pager, not a problem — press `q`, or run
`export AWS_PAGER=""` in your shell first.

`gh` is used only by the last step, which re-registers Jenkins' deploy key and webhook. If it is missing
the deploy still completes and the site still works — only CI is left unregistered, and one command
fixes it afterwards.

**`python3` alone is not enough.** Two Python libraries are needed to scramble the passwords before they
are stored, and neither ships with Python:

| Library | Used by | Without it |
|---|---|---|
| `werkzeug` | `seed-eks-secret.sh` (step 3) | the deploy stops at step 3 |
| `bcrypt` | `seed-jenkins-secret.sh` (step 3b) | the deploy stops at step 3b |

Check both in one line, before you start:

```bash
python3 -c "import werkzeug, bcrypt" && echo "both present"
```

If that fails, the tidiest fix is a throwaway Python folder inside the repo — `seed-eks-secret.sh`
already knows to look there, and it is already ignored by git:

```bash
python3 -m venv services/backend/.venv
services/backend/.venv/bin/pip install werkzeug bcrypt
```

On Linux distributions that refuse a plain `pip install` (you'll see "externally-managed-environment"),
that folder is the answer rather than fighting the system Python. This costs nothing to get wrong
early and is annoying to discover late: the deploy stops **before** it builds anything billable, but
you still have to start over.

Then create one settings file — the only place your own details live:

```bash
cd terraform
cp voteball.tfvars.example voteball.tfvars
cd ..
```

Open `terraform/voteball.tfvars` and set four things: `app_domain` (the web address you want),
`route53_zone_name` (a domain you already manage in AWS Route53, with a trailing dot), `db_password`,
and `notification_email`. Everything else already has a sensible default.

During the deploy you'll also be asked for an admin username and password — those go straight into
AWS's secret vault and are never written to a file.

Keep a backup copy of `voteball.tfvars` (a copy in a password manager is fine) — it isn't in git.

**You no longer need to back up `terraform.tfstate`.** Since 2026-07-21 Terraform's record of what it
built lives in an S3 bucket instead of on this laptop, with every past version kept and two runs
prevented from colliding. `deploy.sh` creates that bucket on first run and writes the small
`terraform/backend.hcl` file that points at it. On a new machine, run
`./scripts/bootstrap-tf-backend.sh` once — it is safe to re-run and recreates nothing that exists.

> **Never delete that bucket** (`<cluster_name>-tfstate-<account_id>`). It belongs to no stack, and
> `destroy.sh` deliberately never touches it — deleting it would destroy the record of what your
> AWS account contains, leaving resources running that Terraform can no longer see.

---

## Put the site online

**Everything, in order:**

```bash
./scripts/deploy.sh
```

It runs the whole sequence and **stops to ask you to confirm** before Terraform creates billed
resources. The steps it performs (kept in step with the script's own numbering — see
`grep -nE '^\s*step "' scripts/deploy.sh` if these ever look out of date):

1. Find the newest database snapshot to restore from.
2. Create the ECR repositories and the three (still empty) secret containers with a small, targeted
   Terraform apply — before the main build below, because the Jenkins install later in this sequence
   needs somewhere to pull its own image from, and somewhere to read its credentials from (the third
   container, `voteball/grafana`, has no such deadline of its own — nothing in step 6's apply reads it
   — but is created here anyway so step 3c has somewhere to seed it before the billed apply).
3. Copy the app's passwords into AWS's secret vault (nothing secret is printed or stored in git). The
   database password is read straight from `voteball.tfvars` (the same file Terraform uses in step 6,
   so the two can't disagree); only the **admin** password is asked for — up front, before any billed
   resource is created. Run `deploy.sh` in a real terminal — see the note below.
3b. Copy Jenkins' own credentials (a GitHub deploy key, a webhook secret, an admin login) into AWS's
    secret vault the same way. Also asked for up front, same reason.
3c. Seed the `grafana_ro` database password (generated, never typed) — and a GitHub token, if one is
    available — into the same vault, for Grafana's PostgreSQL and GitHub data sources. **This step is
    new since 2026-08-24** and closes a real outage: `charts/voteball`'s and `charts/observability`'s
    ExternalSecrets for these credentials are committed **enabled**, so without seeding them first,
    ArgoCD would sync resources asking for a `db_password` that does not exist yet, External Secrets
    Operator would report `SecretSyncedError`, the whole sync would go `phase: Failed`, and — because
    anything failing after `application-cd`'s Promote stage triggers a rollback — every CD run after
    the rebuild would deploy and then immediately roll production back. The GitHub token is
    **optional**: unlike the four credentials above, an unattended run with none supplied does not
    fail or hang — it just seeds `db_password` alone, and the GitHub data source's three panels stay
    blank until a token is added later (see below).
3d. Tell GitHub about the deploy key and webhook that step 3b just minted. This happens **here**, not
    at the end, because step 9 below pushes to `master` — and the webhook left over from the previous
    cluster fires on that push. If GitHub has not been told about the new key by then, the build dies
    on `Permission denied (publickey)` in the middle of an otherwise healthy deploy. The reachability
    check is *not* done here (there is no cluster yet); it runs at step 11b.
4. Mirror the Trivy vulnerability database into ECR, so the CI pipeline never has to pull it from the
   internet during a build.
5. Build and push the Jenkins controller image (CI now runs inside the cluster; see
   [Connect to each part](#connect-to-each-part-dashboards-argocd-jenkins-the-database) below).
6. Build the rest of the AWS infrastructure (**asks you to type `yes`**). This is by far the biggest
   step — around **117 resources in ~13 minutes** — so it is broken out below.
7. Point `kubectl` at the new cluster.
7b. Mint the ArgoCD token the CD pipeline logs in with. Nothing else ever creates it: step 3b can only
    copy it from the environment, and at that point ArgoCD does not exist yet — and since 3b exits
    early once a deploy key is present, re-running the deploy can never fill it in later either. Left
    unset, **every future `application-cd` build fails on an ArgoCD auth error while this script still
    reports success**, which is why it is its own step rather than part of secret seeding. It has to
    run here: the `jenkins-cd` account is created by step 6's apply, reaching ArgoCD needs the kubectl
    context from step 7, and it must land before any push could trigger CD. A no-op on every run
    except the first after a rebuild. Like 3d and 11b it does **not** fail the deploy — it warns and
    prints the standalone fix (`./scripts/seed-argocd-token.sh`).
8. Build the four app container images and upload them.
9. Fill in `charts/voteball/values.yaml` from the Terraform outputs — the database address, the
   certificate, the WAF, the bucket, and the IAM roles all change on every rebuild, so **never edit
   these ten fields by hand** — then resolve the four image digests from ECR and **promote that
   commit to the `release` branch**. ArgoCD watches `release`, not `master` (since 2026-08-23), so
   the branch has to exist and name this cluster's images before step 11 points ArgoCD at it.
10. Install the app and wait for it to come up. A short-lived migration Job applies the database
    schema **once** before the app pods start, rather than every replica racing to do it.
11. Hand ongoing control to ArgoCD, which syncs `charts/voteball` and `charts/observability` from the
    `release` branch.
11b. Check GitHub can actually reach Jenkins — pings the webhook and reports whether DNS resolves, the
     load balancer routes, and Jenkins answered. This is the half of step 3d that needs a running
     cluster, which is why the two are separated. A failure here does **not** fail the deploy: the
     site is already up, and only CI is affected.
11c. Check the **cluster** can resolve the site's own public hostname, and restart CoreDNS if it is
     serving a stale negative answer. App pods start at step 10 and look the hostname up before
     external-dns has created the record; because that name already exists in Route53 for other
     reasons, the answer is "exists, no A record" rather than NXDOMAIN — a negative answer cached for
     the zone's SOA minimum of 24 hours. The visible symptom is not an outage: the site serves the
     internet normally while the in-cluster canary sends nothing, so availability reports a confident
     `1` from its no-data fallback. Also non-fatal, and re-runnable as
     `./scripts/verify-public-dns.sh`.
11d. Restart Grafana, **only if needed**, so it actually picks up the credentials steps 3c and 11
     delivered. `envFromSecret`/`envFromSecrets` project a Secret's keys as environment variables at
     pod start and never again — Grafana is already running by step 6, long before ArgoCD (step 11)
     creates the Secrets these credentials land in — so without a restart Grafana keeps authenticating
     to PostgreSQL with an empty password. The script checks first: no restart if the Secret does not
     exist yet, none if the pod already has the credential projected (a routine re-run). Non-fatal,
     same as 11b/11c, and re-runnable as `./scripts/restart-grafana-datasources.sh`.
11e. Verify the EFK logging pipeline carries a log line end to end, via
     `./scripts/logging/verify-efk.sh`. **This step verifies; it does not enable anything.**
     `charts/logging` ships `enabled: true`, and the deploy *ordering* is what makes that safe: its
     objects (the `Elasticsearch`/`Kibana`/`Fluentd` custom resources) reference CRDs that step 6's
     `terraform apply` installs (`terraform/addon-eck.tf`), and the `logging` ArgoCD Application that
     syncs the chart is not created until step 11 — so the CRDs always exist first without a flag to
     flip, and a git push on its own can never reach the cluster ahead of the apply. Shipping
     `enabled: false` instead would be the 2026-08-25 corollary: a gate that is off in git with
     nothing to turn it on renders zero objects while ArgoCD reports Synced/Healthy on an empty
     manifest. This step deliberately does not check pod status alone: Fluent Bit reports Running whether
     or not it can actually reach the Fluentd aggregator, so `verify-efk.sh` writes a known marker line
     to a `devops-app` pod's stdout and confirms that exact line comes back out of an Elasticsearch
     query — the only check in the pipeline that distinguishes "broken" from "healthy but idle." Also
     **non-fatal**, same as 11b/11c/11d: the application is already up and serving, and this affects
     log search only — CloudWatch keeps receiving every log line regardless, since Fluent Bit fans out
     to both destinations independently. Re-runnable as `./scripts/logging/verify-efk.sh`.

### Grafana's PostgreSQL and GitHub data sources — automatic since 2026-08-24

`deploy.sh` now seeds and wires these up itself (steps 3c and 11d above); nothing manual is required
on a normal rebuild. This section explains what actually happens, and covers the one case that still
needs a person: adding a GitHub token later.

**Why this had to become automatic rather than staying an optional manual step.** The chart flags
that enable these ExternalSecrets (`externalSecret.grafanaEnabled` in `charts/voteball`,
`externalSecret.enabled`/`dbEnabled`/`githubEnabled` in `charts/observability`) are **committed
`true`** — ArgoCD deploys from `release`, so a forkable, real-values chart means they ship on. Leaving
the secret unseeded on a fresh deploy therefore no longer "does nothing"; it actively breaks the
deploy. ESO cannot resolve `db_password` from a still-placeholder `voteball/grafana`, the
ExternalSecret goes `SecretSyncedError`, the resource goes Degraded, ArgoCD's **whole sync** reports
`phase: Failed` — and because anything failing after `application-cd`'s Promote stage triggers a
rollback, every CD run after the rebuild becomes *deploy succeeds, then immediately rolls production
back*. That is exactly what happened on 2026-08-24 (four consecutive failed CD runs) before this
section's fix landed.

**What step 3c actually does.** `./scripts/seed-grafana-secret.sh` generates the `grafana_ro` database
password itself (nothing human types it), then looks for `GITHUB_TOKEN` — in the environment, in
`deploy.env`, or (if a terminal is attached) an optional prompt you can skip with Enter. If none is
supplied, it seeds `db_password` **only** — not an empty `github_token`, which the split
ExternalSecrets (below) are what make safe to omit. Re-running `deploy.sh` never re-seeds
`db_password` or rotates it out from under a live `grafana_ro` role: the script exits immediately once
the secret already holds a real one.

**Why the two credentials are two separate ExternalSecrets, not one.** ESO fails an ExternalSecret's
*entire* sync if even one of its `data` entries cannot be resolved. The original design had a single
ExternalSecret producing both `GF_DATASOURCE_DB_PASSWORD` and `GF_DATASOURCE_GITHUB_TOKEN` — which
meant a deploy with no GitHub token (every unattended run, since it's optional) would have taken the
PostgreSQL data source down too. `charts/observability/templates/externalsecret.yaml` now declares
`grafana-datasource-db` and `grafana-datasource-github` independently, each gated by its own values.yaml
flag, each projected into Grafana via its own `terraform/addon-monitoring.tf` `envFromSecrets` entry
(both `optional = true`). A missing GitHub token now costs three GitHub panels on Jenkins & Delivery;
it no longer touches Business Analytics.

**What step 11d does.** `envFromSecret`/`envFromSecrets` project a Secret's keys as environment
variables **at pod start and never again**. Grafana is already running by step 6 — long before ArgoCD
(step 11) creates the Secrets these credentials land in — so without a restart
`GF_DATASOURCE_DB_PASSWORD` stays unset, and Grafana expands an unset provisioning variable to an
**empty string** rather than failing:

```
failed SASL auth: FATAL: password authentication failed for user "grafana_ro" (SQLSTATE 28P01)
```

`./scripts/restart-grafana-datasources.sh` checks first and restarts only when there is something to
project and it hasn't been projected yet — no churn on a routine re-run. (This is the same trap the
root `CLAUDE.md` records for Jenkins, where a new key in `voteball/jenkins` needs a controller restart
for the same reason — a rule written for one component does not generalise itself to its neighbour,
which is exactly how this was found the first time.) It verifies the projection landed rather than
assuming:

```bash
kubectl exec -n observability deploy/kube-prometheus-stack-grafana -c grafana -- \
  sh -c 'echo "${GF_DATASOURCE_DB_PASSWORD:+set}"'      # prints "set", or nothing at all
```

**Skipping all of this remains safe, if you ever want to.** Both `terraform/addon-monitoring.tf`
`envFromSecrets` entries stay `optional = true`, so Grafana starts normally whether either Secret
exists or not, and nothing else in the stack is affected. Five of the six dashboards render fully
regardless — Application Overview, Kubernetes Cluster, Service Health and AWS Infrastructure are
entirely Prometheus/CloudWatch (CloudWatch authenticates via IRSA, no credential needed — see
`docs/security.md`), and Jenkins & Delivery's build-metrics panels are Prometheus as well. With no
GitHub token, the only thing that stays non-functional is three GitHub panels on Jenkins & Delivery;
with `db_password` never seeded (e.g. `externalSecret.grafanaEnabled`/`dbEnabled` flipped back to
`false` by hand), it's all of Business Analytics.

**Adding a GitHub token later**, or rotating either credential, is still a manual, standalone command
— it was never something a routine rebuild should do on its own:

```bash
GRAFANA_GITHUB_TOKEN='...' ROTATE_WHAT=github_token FORCE_ROTATE=1 ./scripts/seed-grafana-secret.sh
```

(a fine-grained PAT scoped to `Latnook/voteball` alone — see `docs/security.md`'s "Grafana data
sources" section for why that scope and not a classic PAT). `ROTATE_WHAT=github_token` touches only
the token; add `FORCE_ROTATE=1` alone instead only if you genuinely mean to rotate `db_password` too
— that path breaks Business Analytics until the migrate Job's next `ALTER ROLE` release, exactly like
a fresh seed does, so follow it with `./scripts/restart-grafana-datasources.sh` (or another release)
once that has landed. See `docs/maintenance.md`'s GitHub PAT rotation runbook.

CloudWatch is unaffected by any of this — it authenticates by IRSA and needs no secret, so its
dashboard works as soon as `terraform apply` has run.

### What is actually inside step 6

"Build the infrastructure" hides a lot, and step 6 is where nearly all the time goes. It creates:

| | |
|---|---|
| Network | VPC, public / private / database-only subnets, route tables, internet gateway, **NAT gateway** |
| **EKS control plane** | the Kubernetes API — **~8 min**, one of the two long poles |
| **RDS** | restored from the newest snapshot — **~8 min**, the other long pole, *and where your votes come back* |
| Node group | the Spot machines that run the containers |
| Certificates | two ACM certs (site + Jenkins webhook), validated through Route53 |
| Supporting | WAF (rate-limits `/api/vote`), SNS alert topic, S3 bucket, EKS add-ons (VPC CNI, CloudWatch) |
| **Eleven Helm add-ons** | the platform layer — roughly a third of the step |

Those eleven add-ons are the part people don't expect to find here. **None of them are the
application** — they are what the application needs in order to exist:

| Add-on | Why it has to exist before the app |
|---|---|
| AWS Load Balancer Controller | turns an Ingress into a real ALB |
| External Secrets Operator | copies AWS secrets into the cluster |
| external-dns | writes the Route53 records |
| Cluster Autoscaler | adds nodes when the cluster fills up |
| metrics-server | supplies the CPU figures the HPA reads |
| Node Termination Handler | drains Spot nodes before AWS reclaims them |
| kube-prometheus-stack | Prometheus, Grafana, Alertmanager |
| ArgoCD | the GitOps controller that deploys the app in step 11 |
| Jenkins + jenkins-support | CI, in-cluster |
| ECK operator | reconciles the `Elasticsearch`/`Kibana` custom resources in `charts/logging` — a platform add-on for the same reason ArgoCD can't own it: see [`README.submission.md`'s EFK section](../README.submission.md#efk-logging) |

**Why this is one command rather than several you could watch.** The EKS control plane and the RDS
restore each take about eight minutes — but together they take about *eight*, not sixteen, because
Terraform reads its dependency graph, sees they are independent, and runs them at the same time. Seven
of the Helm releases likewise overlap. Step 6's ~13 minutes contains roughly **30 minutes of serial
work**, and splitting it into `-target` stages would put that work back into a queue.

`-target` carries its own trap, too: it prunes the graph to the targeted subset and **silently writes
only the outputs inside it**. That is a bug this project hit for real — see the comment on step 2 in
`scripts/deploy.sh`, where `ecr_registry` went missing from state while everything looked fine, and the
run failed on the *next* step.

**Watching step 6 while it runs.** Terraform reports only its own wait — `Still creating... [6m20s
elapsed]` against opaque resource addresses. Alongside it, `deploy.sh` runs
`scripts/watch-aws-progress.sh` in the background, which asks AWS what is actually happening and
prints each change as it lands:

```
  aws | 00:42  EKS control plane              CREATING
  aws | 01:05  RDS voteball-eks-db            creating
  aws | 02:10  NAT gateway                    available
  aws | 08:31  EKS control plane              ACTIVE            (7m49s)
  aws | 08:40  ASG   Launching a new EC2 instance: i-0abc  [InProgress 50%]
  aws | 09:01  instance i-0abc                running
  aws | 09:34  instance i-0abc checks         system=ok instance=ok   <- OS up
  aws | 09:52  node ip-10-0-39-70             Ready   <- kubelet joined
  aws | 09:58  RDS   event: Restored from snapshot
  aws | 10:11  RDS   event: Finished DB Instance backup
  aws | 10:15  RDS voteball-eks-db            available         (9m10s)
  aws | 12:40  helm releases (10)             argocd cluster-autoscaler external-dns jenkins ...
```

Only *changes* print, each with how long that resource took, and a `still waiting:` line appears if
nothing has moved for two minutes. It is strictly read-only — `describe`/`list` calls, which are
free — and it is a separate process writing to the same terminal, not a pipe, so Terraform's own
output and exit code are untouched. Turn it off with `VOTEBALL_NO_WATCH=1`.

**What it cannot show you, and why.** The EKS control plane is *managed*: AWS publishes exactly one
field for it, `CREATING` → `ACTIVE`, and there are no sub-steps to display at any price — so those
~8 minutes are one line, not a progress bar. Node provisioning is visible (the Auto Scaling group's
launch activities, then EC2 **status checks** going `initializing` → `ok`, which is the box booted
and answering, then the node going `NotReady` → `Ready`, which is the kubelet up). RDS is the
best-instrumented of the three, because it publishes an event stream in plain English.

Terraform's own lines still tell you the rest: each resource prints `Creation complete after
<duration>` as it lands.

**Both secrets are seeded at steps 3/3b, before the big apply at step 6, and that order matters.**
Step 6 creates Jenkins and its ExternalSecret together, and External Secrets Operator copies the AWS
secret into the cluster once at creation and then only once an hour. If the vault were still empty at
that moment, Jenkins would boot with no admin account and reject every login for an hour — while the
deploy reported complete success throughout. (Hit for real on the 2026-07-31 rebuild.)

Step 9 commits and pushes `values.yaml` for you and then promotes that commit to the `release`
branch, because ArgoCD deploys from `release` and not from
this laptop. You don't need to do anything.

### Run it in a real terminal

Right at the start — **before Terraform builds anything billed** — the script asks for four things: the
app's admin password, and a username + password for Jenkins' own login (nothing is echoed for either
password), then runs the rest unattended. (The database password isn't asked for at all; it's read from
`voteball.tfvars`.) Asking up front is deliberate: a missing value fails in seconds, not after a
~15-minute billed `terraform apply`. That also means **`deploy.sh` cannot run in a window that has no
keyboard attached** — a script, a cron job, or a tool running it in the background. There it stops with:

```
ERROR: no terminal is attached, and DB_PASS / ADMIN_PASSWORD / JENKINS_ADMIN_USER /
JENKINS_ADMIN_PASSWORD are not all set.
```

That is the script refusing to continue rather than saving a blank password. To run it without a
keyboard, supply all four up front instead (the database password still comes from `voteball.tfvars`,
but you can override it here too):

```bash
ADMIN_USERNAME=admin ADMIN_PASSWORD='...' \
JENKINS_ADMIN_USER='...' JENKINS_ADMIN_PASSWORD='...' \
VOTEBALL_AUTO_APPROVE=1 ./scripts/deploy.sh
```

`VOTEBALL_AUTO_APPROVE=1` skips Terraform's "type yes" prompt. On its own it is **not** enough to
make the deploy unattended — without the other four it still stops in the preflight check, before any
billed resource is created.

### Or keep them in `deploy.env`

Typing those four every time gets old. Put them in a file called **`deploy.env` in the repo root** and
`deploy.sh` loads it automatically at startup, so an unattended run needs only
`VOTEBALL_AUTO_APPROVE=1 ./scripts/deploy.sh`:

```bash
ADMIN_USERNAME=yourname
ADMIN_PASSWORD=yoursecret
JENKINS_ADMIN_USER=yourname
JENKINS_ADMIN_PASSWORD=yoursecret
GRAFANA_GITHUB_TOKEN=yourfinegrainedpat
```

Plain `KEY=value` lines, no `export` needed and no quotes required. It is **gitignored and holds
plaintext passwords** — same category as `terraform/voteball.tfvars`, so keep it `chmod 600` and never
commit it. The database password is deliberately *not* in here; it is read from `voteball.tfvars` so
the two can't drift apart. `GITHUB_TOKEN` is the one line here that's genuinely **optional** — step
3c seeds `db_password` alone and does not fail or prompt when it's absent; add it only once you have a
fine-grained PAT you want Grafana's GitHub data source to use (see "Grafana's PostgreSQL and GitHub
data sources" above).

Anything you set on the command line beats the file, so you can still override one value for a single
run — `ADMIN_PASSWORD='newsecret' ./scripts/deploy.sh` — without editing it.

> Sourcing it into your own shell (`source deploy.env`) is **not** a substitute and looks like it
> should work. Those lines carry no `export`, so the values stay in your shell and never reach
> `deploy.sh`, which then prompts exactly as if the file weren't there. Let the script load it.

**Re-running `deploy.sh` is safe, but step 3 reseeds the admin secret every run — two things follow
from that:**

- It issues a **new admin session key**, signing out anyone currently logged into the admin page.
  Nothing breaks — you just log in again.
- It **resets the admin username back to `admin`** unless you pass `ADMIN_USERNAME`. `deploy.sh`
  prompts for the *password* but never the *username*, so a custom username silently reverts. If you
  have set one, carry it through the rebuild:

  ```bash
  ADMIN_USERNAME='yourname' ADMIN_PASSWORD='yoursecret' ./scripts/deploy.sh
  ```

  (The database password does *not* need passing — it is read from `voteball.tfvars`.) See
  [Change the admin username or password](#change-the-admin-username-or-password) below.

**The Jenkins credentials behave the opposite way, and this surprises people.** `deploy.sh` prompts
for a Jenkins username and password on **every** run, but `seed-jenkins-secret.sh` **exits without
writing anything** once the vault already holds a deploy key — so on a re-run those answers are simply
discarded and the old Jenkins login stays in force. The deploy still reports success; nothing warns
you. That guard is deliberate (rewriting the secret would also replace the GitHub deploy key and
webhook secret, breaking CI until both were re-registered), but it means **you cannot change the
Jenkins password by re-running the deploy.** To actually change it:

```bash
FORCE_ROTATE=1 JENKINS_ADMIN_USER='yourname' JENKINS_ADMIN_PASSWORD='yoursecret' \
  ./scripts/seed-jenkins-secret.sh
```

That mints a **new deploy key and a new webhook secret** as well, so afterwards you must re-register
both on GitHub (`docs/cicd.md`, "First-time setup runbook", steps 1 and 4) or the webhook is rejected
and the pipeline's final push is denied.

**After a full `destroy.sh` → `deploy.sh` cycle none of this applies**: the vault is deleted with the
stack, so both scripts seed from scratch and every credential you type is the new one.

**`destroy.sh` needs no credentials at all** — it never touches the vault. Your AWS login is the only
thing required.

**⚠️ Confirm the alert email — every single rebuild.** Check your inbox for an AWS confirmation link
and click it. Teardown deletes the notification topic, so each deploy recreates the subscription in a
*pending* state, and AWS will not deliver to an unconfirmed address.

This now matters far more than it used to: as well as milestone emails, this address receives the
**operational alerts** (crashlooping pods, failed migrations, missing backups). An unconfirmed
subscription means alerts are published successfully and delivered to nobody — a failure that only
shows up when something else is already wrong. Verify with:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=terraform output -raw sns_topic_arn)" \
  --region <your region> --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output text
```

If it prints `PendingConfirmation`, no alert will ever reach you.

Give it a few minutes, then open **https://&lt;your app_domain&gt;**.

**Later, after changing app code:** just `git push` — CI rebuilds the images and ArgoCD deploys them.
To do it by hand instead, run `./scripts/deploy.sh` again.

---

## Check it worked

```bash
kubectl get pods -n devops-app          # everything should say "Running"
curl -sf https://<your app_domain>/api/options | head -c 120   # should print leagues/clubs/parties
```

Open the site in a browser and cast a vote — it should land and show on the results page.

---

## Change the admin username or password

The admin login lives in **one place** — the `voteball/app-secret` secret in AWS Secrets Manager,
never in git or Terraform state. Change it with the same script the deploy uses:

```bash
ADMIN_USERNAME='newname' ADMIN_PASSWORD='newsecret' ./scripts/seed-eks-secret.sh
```

- **Always pass `ADMIN_USERNAME`.** Leave it out and it defaults to `admin` — so omitting it while
  meaning to change only the password silently renames your account to `admin`.
- You do **not** pass the database password; it is read from `voteball.tfvars`. The script rewrites
  the whole secret each run — re-reading the DB password from there and re-hashing the admin one.
- The admin password is stored **hashed** (one-way), never in the clear. If you forget it, no one can
  recover it — you just run this again with a new one.
- Changing the secret rotates the session key too, so any active admin login is signed out. That is
  the intended behaviour when rotating a password.

**The running app will not see the change immediately** — there are two delays:

1. External Secrets Operator copies the AWS secret into the cluster on a timer (`refreshInterval:
   1h`).
2. The backend reads these values as environment variables, fixed when the pod starts — so even once
   the in-cluster secret updates, the running pods keep the old values until restarted.

To apply the change now instead of waiting up to an hour:

```bash
# 1. Force the operator to pull from Secrets Manager immediately:
kubectl annotate externalsecret app-secret -n devops-app force-sync="$(date +%s)" --overwrite

# 2. Confirm the in-cluster secret updated (should print your new username):
kubectl get secret app-secret -n devops-app -o jsonpath='{.data.ADMIN_USERNAME}' | base64 -d; echo

# 3. Only then restart the backend so it re-reads the values:
kubectl rollout restart deployment/backend -n devops-app
```

Do step 2 **before** step 3 — restart the backend before the in-cluster secret has updated and the
fresh pod just reloads the old value. Only `backend` needs restarting; the worker and jobs mount the
same secret but use only the (unchanged) database credentials.

> **On a full rebuild**, this same reseed happens as one of the early steps of `deploy.sh`, which is
> why a custom username has to be passed on the `deploy.sh` command line — see the note under
> [Put the site online](#run-it-in-a-real-terminal).

---

## Connect to each part (dashboards, ArgoCD, Jenkins, the database)

**Only the website is on the internet.** Grafana, Prometheus, Alertmanager, ArgoCD, Jenkins and the
database have no public web address at all — you open a private tunnel from your own machine each
time. That means your AWS login *is* the front door; the passwords below are a second layer, not the
only one.

| Part | How you get in | What proves it's you |
|---|---|---|
| The website | `https://<your app_domain>` | nothing — it's public on purpose |
| The admin page | `https://<your app_domain>/admin` | username + password → 12-hour token |
| Kubernetes | `kubectl`, after `update-kubeconfig` | your AWS login |
| Grafana | tunnel → `http://localhost:3000` | AWS login + a generated password |
| Prometheus | tunnel → `http://localhost:9090` | AWS login (it has no password) |
| Alertmanager | tunnel → `http://localhost:9093` | AWS login (it has no password) |
| ArgoCD | tunnel → `https://localhost:8081` | AWS login + `admin` password |
| Jenkins | `kubectl port-forward` → `http://localhost:8080` | your AWS login (cluster access) + a Jenkins login |
| The database | a throwaway pod inside the cluster | being inside the cluster + the DB password |
| ECR, S3, secrets, SNS, logs | the `aws` command | your AWS login |

### First: point kubectl at the cluster

Needed on a new machine, and **again after every rebuild** — the cluster's address changes, and the
old entry fails with a confusing certificate or connection error:

```bash
aws eks update-kubeconfig --region <your region> --name <your cluster_name>
kubectl get nodes        # nodes "Ready" means you're in
```

This doesn't create a password. It tells `kubectl` to ask AWS for a short-lived pass on every
command, so there is no cluster password to lose — and removing someone's AWS access removes their
cluster access at the same moment.

### The website and the admin page

```
https://<your app_domain>          the ballot
https://<your app_domain>/results the results
https://<your app_domain>/admin   the admin page
```

Those are the canonical URLs. nginx serves them directly and **301-redirects the `.html` forms onto
them** (`/admin.html` → `/admin`), so an old bookmark still works but lands on the clean address.

The admin page is deliberately **not linked** from the site, but that's not what protects it: every
admin action needs a signed token that only a correct username and password can obtain, and it
expires after 12 hours. To change those, see
[Change the admin username or password](#change-the-admin-username-or-password) above.

### Grafana, Prometheus and Alertmanager

Run one of these and **leave it running** (it blocks — use a second terminal), then open the link:

```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana      3000:80    # http://localhost:3000
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus   9090:9090  # http://localhost:9090
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093  # http://localhost:9093
```

Grafana's username is `admin`. Its password is generated fresh at install time (deliberately — a
fixed one would have to be written down in the repo), so **it is different after every rebuild** —
and also different after the namespace was renamed from `monitoring` to `observability`, since that
recreates the release from scratch. If you saved the old password, it no longer works; print the
current one with:

```bash
kubectl get secret kube-prometheus-stack-grafana -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**`grafana-cli` runs inside the Grafana pod**, if you need it (checking plugin versions, mostly):

```bash
kubectl exec -it -n observability deploy/kube-prometheus-stack-grafana -c grafana -- grafana-cli --help
```

Treat it as **read-only**. Nothing it writes survives: Grafana here has no disk of its own
(deliberately — see "no PVC" in `docs/observability.md`), so a `grafana-cli plugins install` is gone
the next time the pod restarts, which on Spot nodes is roughly daily. A plugin that should stay
belongs in the `helm_release` values in `terraform/addon-monitoring.tf`, and a dashboard belongs in
`charts/observability/dashboards/` (below) — both survive a rebuild; a CLI call does not.
`grafana-cli admin reset-admin-password` is worse than useless here: it changes the running password
without changing the Secret above, so the real password and the one every script reads stop matching,
and the next pod restart throws your new one away anyway.

Prometheus and Alertmanager have **no login at all**. That is on purpose, not an oversight: the only
way to reach them is to already hold cluster access, so a second password would protect nothing and
would have to be stored somewhere.

Where to look once you're in:

- **Grafana** → Dashboards → six are this project's own, provisioned from git and reachable without
  digging through a folder: **Application Overview** (`voteball-app` — traffic, error rate, latency,
  votes cast, which build is running), **Kubernetes / Cluster** (`voteball-k8s` — node/pod health,
  restarts, throttling), **Jenkins & Delivery** (`voteball-delivery` — queue, executors, build
  outcomes, plus commit/contributor/issue counts from GitHub), **Service Health & Alerts**
  (`voteball-alerts` — what's firing right now, and the SLOs), **Voteball Business Analytics**
  (`voteball-business` — votes per day, top parties, vote switching, read through `grafana_ro`),
  **AWS Infrastructure** (`voteball-aws` — RDS and ALB metrics from CloudWatch). Two of those need the
  optional credential seeding step above to show real data — **Voteball Business Analytics** (Postgres)
  fully, and three panels on **Jenkins & Delivery** (GitHub commits/contributors/issues) — without it
  those panels are empty, not missing. **AWS Infrastructure needs no seeding at all**: CloudWatch
  authenticates via IRSA (see `docs/security.md`), so it works as soon as `terraform apply` finishes.
  Everything else in that list is a bundled kube-prometheus-stack dashboard, e.g. the
  `kube-prometheus-stack` folder's *Kubernetes / Compute Resources / Namespace (Pods)*, filtered to
  `devops-app`, for the app's raw CPU and memory use.
- **Prometheus** → **Status → Rule Health** lists the alert rules. If your rules are missing there,
  they are not being checked at all — see `charts/voteball/templates/prometheusrule.yaml` for the
  label that causes this. `kubectl get prometheusrules` would still look perfectly fine.
- **Alertmanager** → the front page shows what is firing *after* grouping, which is the real answer
  to "would this have emailed me?"

**To add a dashboard**, drop a Grafana-exported JSON file into `charts/observability/dashboards/` and
push. `templates/dashboards.yaml`'s `.Files.Glob "dashboards/*.json"` wraps every file it finds in a
ConfigMap labelled `grafana_dashboard: "1"`, and Grafana's sidecar picks it up on its next 60-second
poll — no per-dashboard template to write, no import button to click. Give the dashboard a stable
`"uid"` (used as the ConfigMap name) and confirm it renders offline first:

```bash
helm template observability charts/observability --namespace observability | grep 'dashboard-'
```

### ArgoCD

Same idea, but it speaks HTTPS, so your browser will warn about the certificate — that's expected:

```bash
kubectl port-forward -n argocd svc/argocd-server 8081:443     # then https://localhost:8081
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

Username is `admin`. **Fetch that password fresh each time rather than saving it** — ArgoCD generates
a new one on every rebuild, so a stored copy stops working after any `destroy.sh` → `deploy.sh` cycle.
Unlike the app and Jenkins logins, it is not something you choose.

If you only want to know whether the cluster matches git, you don't need the UI:

```bash
kubectl get applications -n argocd      # "Synced / Healthy" is the answer
```

**The UI is read-only by convention, and there is a check that enforces it.** Everything ArgoCD is
configured with is in two files — `terraform/addon-argocd.tf` (the release and `argocd-cm`) and
`argocd/voteball-application.yaml.tmpl` (the `AppProject` and the `Application`). To confirm nothing
was changed through the UI:

```bash
./scripts/render-argocd-app.sh --check
```

It fails on three things: the live `Application`/`AppProject` differing from the template, an
`Application` or `AppProject` that no file in this repo declares, and any repository or cluster
credential registered by hand. Worth knowing *why* this is a separate check rather than something
ArgoCD does itself: `selfHeal` reconciles the contents of `charts/voteball`, but nothing reconciles
the `Application` that points at it. An edit to sync policy or destination made in the UI is the one
kind of drift GitOps cannot self-correct.

Settings under `argocd-cm` are a softer case — the Helm release owns that ConfigMap, so the next
`terraform apply` reverts a UI change to it regardless. The check makes it visible; Terraform undoes it.

### Kibana, Elasticsearch and Fluentd (the log search stack)

**Kibana is the only one of the three with a UI, and it is on the public internet** — unlike Grafana,
ArgoCD and Jenkins above, you do not need `port-forward`:

```
https://kibana.voteball.latnook.com
```

That host is the **third member of ALB group `voteball`**, so it shares one load balancer with the
website and the Jenkins webhook, and its certificate comes from ACM the same way theirs do. The
username is **`elastic`** — ECK generates the password when it creates the Elasticsearch resource, so
like Grafana's it is **different after every rebuild** and is not written down anywhere. Print the
current one with:

```bash
kubectl get secret voteball-logs-es-elastic-user -n logging \
  -o go-template='{{.data.elastic | base64decode}}{{"\n"}}'
```

First time in, Kibana asks for a **data view** before it will show anything: create one on the index
pattern `voteball-logs-*` with `@timestamp` as the time field. There is one index behind a write
alias, rolled over daily and **deleted after 7 days** — see below for why that is not a mistake.

**Elasticsearch has no public route, deliberately.** Nothing outside the cluster should reach it, so
it is reached the same way Prometheus is:

```bash
kubectl port-forward -n logging svc/voteball-logs-es-http 9200:9200
# then, in a second terminal -- `-k` because ECK's certificate is self-signed INSIDE the cluster
# (the real ACM certificate lives on the ALB in front of Kibana, not here):
curl -k -u elastic:<password> https://localhost:9200/_cat/indices?v
curl -k -u elastic:<password> https://localhost:9200/voteball-logs/_count
```

**Fluentd has no interface at all** and never will — it is a pipe, not a service. You observe it:

```bash
kubectl logs -n logging deploy/fluentd -f        # what it is doing
kubectl get pods -n logging                      # whether it is up
```

**But "up" is not "working", and this is the one that matters.** Fluent Bit forwards to Fluentd and
buffers silently when it cannot — so a broken ingest path looks exactly like a quiet site with nothing
to log. The only check that tells them apart asks the product itself:

```bash
./scripts/logging/verify-efk.sh
```

It writes a marker into a real `devops-app` pod's log and confirms that document arrives in the index,
which is also what deploy step 11e runs. Reading the ArgoCD Application's colour, or the pods' status,
answers a different and easier question.

**Three things that look wrong and are not:**

- **Cluster health is `yellow`, permanently.** One Elasticsearch node, no replica shard, by design —
  nothing alerts on it, because an alert that fires forever is one people learn to ignore.
- **Logs older than 7 days are gone from Kibana.** CloudWatch Logs holds the authoritative copy;
  Elasticsearch is the *search* surface, not the archive. Reaching further back means Logs Insights.
- **Only `devops-app` logs are here.** Fluent Bit is scoped to that namespace on purpose — `ci`,
  `argocd` and `monitoring` were about 95% of the volume and were dropped in the 2026-08-03 cost pass.

### Jenkins (the build server)

Jenkins runs **inside the cluster** now (namespace `ci`) — there is no separate machine, nothing to
start or stop, and no bill for it beyond the pods it uses on nodes the cluster already runs. It comes up
and goes down with the cluster itself. Reach the UI the same way you'd reach Grafana or ArgoCD:

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080   # then browse http://localhost:8080
```

Its web address (`https://jenkins.<your app_domain>/`) is only open for one path — the GitHub webhook —
so the UI itself is not reachable from the internet at all; the port-forward above is the only way in.
One thing that catches people out:

- **The login password can't be recovered.** Only a one-way hash of it is stored, so if you forget it,
  re-set it: `JENKINS_ADMIN_USER=... JENKINS_ADMIN_PASSWORD='...' ./scripts/seed-jenkins-secret.sh`,
  then force a fresh controller so it re-reads the secret:
  `kubectl delete pod -n ci -l app.kubernetes.io/component=jenkins-controller`. See `docs/cicd.md`.

### The database

The database sits in a private part of the network with **no route to the internet**, and it only
accepts connections from the cluster's own machines — nothing on your laptop can dial it directly.
To get a database prompt, borrow a temporary pod inside the cluster:

```bash
kubectl run psql-shell -n devops-app --rm -it --restart=Never \
  --image=postgres:17-alpine --labels=app=migrate \
  --overrides='{"spec":{"containers":[{"name":"psql-shell","image":"postgres:17-alpine","stdin":true,"tty":true,
    "command":["sh","-c","PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME"],
    "envFrom":[{"configMapRef":{"name":"app-config"}},{"secretRef":{"name":"app-secret"}}]}]}}'
```

Three details there matter. It must be in the `devops-app` namespace (elsewhere the firewall rules
block it); the label must be **`app=migrate`** and not `app=backend`, or live visitor traffic gets
routed into your shell; and the password comes from the existing secret rather than being typed, so
it never lands in your shell history.

#### With pgAdmin (or DBeaver, or a local `psql`)

A desktop client cannot borrow a pod the way the command above does, so it needs the connection
brought out to your machine instead:

```bash
./scripts/db-tunnel.sh            # listens on localhost:5433; LOCAL_PORT=5555 to change it
```

Leave it running and point the client at **localhost / 5433 / postgres / postgres**, SSL mode
**require**, with the password being `db_password` from `terraform/voteball.tfvars`. Ctrl-C closes
the tunnel and deletes the pod it created.

What the script does is chain two hops that each already exist: a throwaway `socat` pod inside the
cluster relays port 5432 on to the database, and `kubectl port-forward` relays your machine to that
pod through the Kubernetes API server. Nothing is opened to the internet — the traffic rides the same
authenticated API connection `kubectl` already uses, and the database's firewall still only ever sees
a connection from a cluster machine.

Two things about it are easy to get wrong by hand:

- The pod carries the label **`app=migrate`**, for the same reason the `psql` shell above does. A pod
  without one of the allowed labels resolves DNS fine and then has every connection silently dropped
  by the namespace's default-deny egress rule — it looks like a hung database, not like a firewall.
- Use SSL mode `require`, **not** `verify-full`. `socat` passes the raw bytes through, so encryption
  is still negotiated end-to-end between your client and the database — but the database's certificate
  names its real AWS endpoint, and your client is dialling `localhost`, so full verification fails.

### The AWS side (images, backups, secrets, alerts, logs)

No tunnels here — these are AWS services, so the `aws` command with your normal login is all you
need. Every name is read from Terraform rather than written down:

```bash
cd terraform

# Container images
aws ecr get-login-password --region <your region> \
  | docker login --username AWS --password-stdin "$(terraform output -raw ecr_registry)"

# Nightly database dumps
aws s3 ls "s3://$(terraform output -raw s3_bucket)/backups/" --human-readable

# The app's secret (metadata only — see the warning below)
aws secretsmanager describe-secret --secret-id voteball/app-secret --region <your region>

# Alert emails: check the subscription says Confirmed, not PendingConfirmation
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform output -raw sns_topic_arn)" --region <your region>

# Logs that outlive the cluster
aws logs tail "/aws/containerinsights/$(terraform output -raw cluster_name)/application" \
  --since 30m --region <your region>
```

> **Avoid `aws secretsmanager get-secret-value`** unless you really need the value — it prints the
> secret to your screen and into your shell history. `describe-secret` confirms it exists without
> revealing anything. The whole design is that no person has to read it: the operator copies it into
> the cluster automatically, and no secret value is ever in git or Terraform state.

### If a connection won't work

| What you see | Almost always |
|---|---|
| `kubectl` hangs or complains about certificates | The cluster was rebuilt — re-run `aws eks update-kubeconfig` |
| `kubectl` times out (no error, just waits) | Your home IP changed and is no longer in the cluster's allow-list. AWS drops the packets rather than refusing them, so it looks like a dead cluster. Run `./scripts/refresh-api-cidr.sh`, then `cd terraform && terraform apply -var-file=voteball.tfvars` |
| Port-forward says the service doesn't exist | A chart upgrade renamed it — run `kubectl get svc -n observability` and use the real name |
| Grafana rejects the password | It's regenerated on every rebuild — print it again |
| `localhost:3000` shows nothing | The tunnel closed — it dies with its terminal, silently |
| `kubectl port-forward -n ci svc/jenkins` fails | The cluster (and Jenkins with it) is torn down, or the pod is mid-reschedule after a Spot reclaim — retry in a few seconds |
| A push doesn't trigger a build | Check the webhook is pointed at `https://jenkins.<your app_domain>/github-webhook/` (repoints on every rebuild — the hostname is stable via external-dns, but a stale webhook from a much older setup can still exist in GitHub's settings) |
| Alerts never arrive | The email subscription is still `PendingConfirmation` |

---

## Take it down (stop paying)

```bash
./scripts/destroy.sh
```

It removes things in the order that actually works, and **asks you to confirm** before deleting the
infrastructure. Order matters:

1. **All three ArgoCD Applications first** (`voteball`, `observability` and — since the EFK logging
   pass — `logging`) — otherwise ArgoCD notices what you deleted next and puts it straight back,
   `observability`'s `NetworkPolicy`/dashboard/alert objects and `logging`'s Elasticsearch/Kibana
   custom resources included.
2. **All three Ingresses next** — the site's, Jenkins' webhook, and (since the EFK logging pass)
   Kibana's. All three share one load balancer, and it is only released when *none* of them is left.
   Deleting some and not all of them leaves it running, and a leftover load balancer keeps network
   interfaces alive that block the network from being deleted. This is the difference between a
   teardown that takes ten minutes and one that appears to hang for twenty. The Kibana Ingress is
   deleted here, explicitly, rather than left to step 4's `helm uninstall logging` — that step runs
   *after* step 3 below already starts waiting for the load balancer, which would reproduce the same
   hang for the group's third member.
3. **Wait** for the load balancer to actually disappear.
4. **Uninstall this stack's own Helm releases — all SIX of them** — the app, Jenkins, Jenkins' support
   chart, kube-prometheus-stack (Prometheus/Grafana/Alertmanager), the EFK logging chart, and the ECK
   operator — while the cluster is still healthy. Removing kube-prometheus-stack here matters for the
   next step: it deletes the Prometheus and Alertmanager custom resources, so the operator that watches
   them has nothing left to act on. **ECK comes out in a specific order, and it's the reverse of what
   you'd guess**: the `Elasticsearch`/`Kibana` custom resources are deleted first, then the `logging`
   chart, and the ECK operator itself comes out last. Deleting the operator first would leave those
   deletes stuck — its `ValidatingWebhookConfiguration` intercepts every write to `*.k8s.elastic.co`
   objects, and with no operator left to answer it the delete just hangs, the same class of hang as
   `kubernetes_namespace.ci` sitting `Terminating` forever with no ESO controller left to clear its
   finalizers. One side-effect worth knowing: ECK's `volumeClaimDeletePolicy` deletes the Elasticsearch
   PVC when its custom resource goes, so — unlike step 5 below for the observability PVCs — there is no
   separate orphaned-EBS cleanup needed for EFK's volume.
5. **Delete the observability PVCs.** A StatefulSet's volume claim survives `helm uninstall`, by
   design — Kubernetes keeps it so a recreated StatefulSet can rebind its data. Left behind it's an
   orphaned EBS volume that bills forever and blocks nothing, so the teardown would report success
   while leaking it. This has to run *after* step 4, not before: while the operator and its
   Prometheus/Alertmanager custom resources are still around, deleting the StatefulSet doesn't work —
   the operator just recreates it (and a fresh PVC, and a fresh EBS volume) within seconds. Once step
   4 has removed the release, there's no operator left to do that, so the plain PVC delete here is
   enough.
6. **Remove the DNS records** for both `<your-domain>` and `jenkins.<your-domain>`, in case
   external-dns was deleted before it noticed. It only ever touches records it created for this
   cluster; your email and other records are never eligible.
7. **Then** delete everything else — and confirm before it starts, because this is the irreversible
   part.

A final database snapshot is taken automatically, so the next `./scripts/deploy.sh` restores your
votes. (This changed on 2026-07-20 — teardown used to discard them.)

**Step 7 narrates itself too.** The same background watcher used by the deploy runs during the
teardown, and destroy is the better-instrumented half of the two — the final snapshot is the one
thing in this whole stack that reports a real percentage:

```
  aws | 01:20  final snapshot voteball-eks-db-final-20260821  creating 34%
  aws | 03:05  final snapshot voteball-eks-db-final-20260821  available 100%   (2m45s)
  aws | 03:12  RDS voteball-eks-db            deleting
  aws | 04:40  instance i-0abc                shutting-down
  aws | 05:02  instance i-0abc                terminated
  aws | 06:02  network interfaces left        11 (3 detached)
  aws | 09:10  EKS control plane              gone              (8m31s)
```

That last interface count is the useful one: detached interfaces are exactly what pins a subnet and
produces the long "Still destroying... subnet" silence, so you can watch the reaper drain them
instead of wondering whether the teardown has died. `VOTEBALL_NO_WATCH=1` turns it off.

**Two things `destroy.sh` deliberately does NOT delete**, and neither should be added to it:

| Kept | Why |
|---|---|
| The Terraform **state bucket** | It holds the record of what is being deleted. Removing it mid-teardown would orphan anything left behind. |
| **Database snapshots** | They are the restore point for the next deploy. Prune old ones by hand, keeping the newest. |

**What is NOT kept, and catches people out: the nightly database dumps in S3.** The bucket holding them
is deleted by `terraform destroy`, during the same run it would supposedly be insuring — `terraform/s3.tf`
sets `force_destroy = true`, which means "delete this bucket even though it still has files in it".
**The nightly dumps are not teardown insurance.** What actually carries your votes across a rebuild is
the final snapshot, plus retained automated backups. If you want the dumps too, copy them off first:

```bash
aws s3 sync "s3://$(terraform -chdir=terraform output -raw s3_bucket)/backups/" ~/voteball-backups/
```

**Prune snapshots by date, never by name — the names lie.** A snapshot's identifier embeds the date the
*stack was deployed*, not the date the snapshot was taken. On a teardown today of a stack built three
days ago, the brand-new final snapshot is named after that older date and looks stale. Sort on
`SnapshotCreateTime`, which is the only trustworthy field (this is also why `find-latest-snapshot.sh`
sorts on it):

```bash
aws rds describe-db-snapshots --snapshot-type manual --region <your region> \
  --query 'sort_by(DBSnapshots[?starts_with(DBInstanceIdentifier, `voteball`)], &SnapshotCreateTime)[].{created:SnapshotCreateTime,id:DBSnapshotIdentifier,status:Status}' \
  --output table
```

Note also that `SnapshotCreateTime` is stamped when the snapshot **finishes**, not when it starts — so a
snapshot in progress may briefly appear older than one taken minutes earlier.

Snapshots bill on the space actually used, not the disk size allocated, so keeping several old ones
costs very little. Keeping one from *before* any large data change is worth more than it costs: votes
can be deleted through the admin page, so a newer snapshot does not always contain more than an older
one, and "keep only the newest" can quietly discard history.

Jenkins is **not** in this list any more — it is part of the same stack as the app now (namespace `ci`,
installed by the same `terraform apply`), so `terraform destroy` removes it along with everything else.
There is nothing left to keep running between sessions: its configuration lives in git as JCasC, and
its build history was already designed to be disposable (see `docs/cicd.md`).

**One thing does not survive a teardown: Jenkins' secret vault** (as noted further up under [Put the
site online](#put-the-site-online)). The rebuild therefore generates a **new GitHub deploy key and a
new webhook secret**, and GitHub is left holding the previous pair. Until both are replaced the webhook
is rejected and the build's final push is denied — with nothing in the deploy output warning you,
because the deploy itself genuinely succeeded.

**Since 2026-08-03 `deploy.sh` handles this for you** by calling
`./scripts/register-github-ci.sh`. That script reads the new key and secret straight from Secrets
Manager (never from the deploy log, which would leave the webhook secret in a file on disk), replaces
both on GitHub, and prints neither. It is idempotent — it compares the vault's deploy-key fingerprint
against the keys GitHub already holds and does nothing when they match — so re-running `deploy.sh`
without a rebuild changes nothing.

**It runs in two halves, at two different points in the deploy, and the split is deliberate.**
Registration happens at **step 3d** (renumbered from 3c on 2026-08-24 when the Grafana-secret seeding
step was inserted ahead of it), right after the key is minted and long before anything can push
(`SKIP_PROBE=1`). The reachability probe happens at **step 11b**, once Jenkins is actually serving
(`PROBE_ONLY=1`).

> **Why not do both at the end, as it used to?** Step 9 pushes `values.yaml` to `master`, and the
> webhook that survived the previous cluster fires on that push. If the key has not been registered
> yet, Jenkins fetches with a key GitHub has never been told about and the build dies on
> `Permission denied (publickey)` — in the middle of a deploy that is otherwise going perfectly.
> Measured on the 2026-08-03 rebuild: build 1 failed at **19:13:18Z**, the key was registered at
> **19:13:39Z**. Twenty-one seconds. Registering first closes the window; the probe cannot move
> earlier because there is no Jenkins to ping until step 6 has built the cluster.

The probe **tells you what a failure means**, which is more useful than a bare pass/fail. A successful
ping proves the DNS name resolves, the load balancer routes, and Jenkins is up and answering — the
whole path except the last step.

> **It does not prove the shared secret is right, and no status code can.** Tested against the live
> stack on 2026-08-03: a webhook registered with a deliberately wrong secret still returned **200** in
> 0.58 s, and forged push requests (no signature, and a bogus signature) also returned **200** while
> triggering nothing at all — no build, no log line. Jenkins validates the signature and then silently
> discards the event. That is correct fail-closed behaviour (and confirms an attacker cannot trigger
> your builds), but it means **a stale webhook secret is invisible from both ends**: GitHub shows a
> green delivery, Jenkins shows nothing, and the only symptom is that pushes quietly stop producing
> builds. If that happens, re-run `./scripts/register-github-ci.sh` with `FORCE_REGISTER=1`.

It deliberately **does not retry until it passes**. The failure it would be retrying against — DNS
negative caching, described under [If something breaks](#if-something-breaks) — lasts up to 15 minutes,
which no sensible retry budget outlasts; a loop that eventually gave up would print a warning on a
perfectly good deploy and train you to ignore warnings. Instead it probes briefly and classifies the
result by the delivery's **`duration`**:

| Result | Meaning | Action |
|---|---|---|
| `200` | DNS resolves, ALB routes, Jenkins answered (NOT proof of the secret) | none |
| fails in **~0 s** | GitHub never opened a connection — DNS cache from teardown | none; clears within ~15 min |
| fails with a **realistic duration** | connection made and refused — Jenkins down, or no healthy target | **warns**; needs you |

That middle row is why the duration matters: it is the common case after a rebuild and it is *not* a
fault, so treating it as one would be noise. The bottom row is a genuine fault that the old
"just retry" approach would have hidden.

It is **deliberately not fatal**: if the GitHub call fails, the deploy still reports success, because
everything else did succeed and the site is up. You get a warning instead, and the fix is one command:

```bash
./scripts/register-github-ci.sh          # safe any time; no-op when already correct
FORCE_REGISTER=1 ./scripts/register-github-ci.sh   # re-register even if it looks correct
```

Its own tests live in `scripts/tests/test-register-github-ci.sh` and run **online**, against real
GitHub and a live cluster — unlike the other suites in that folder, which stub their dependencies:

```bash
scripts/tests/test-register-github-ci.sh                     # safe subset
scripts/tests/test-register-github-ci.sh --test-fault-branch # also stops Jenkins for ~2 min
```

That choice is deliberate. What this script has to get right is not its own control flow, it is what
GitHub and Jenkins actually do — and a stub can only ever confirm the assumptions you already hold.
Written online, the test immediately falsified one of them (the "wrong secret returns 401" claim
above). It cleans up after itself and leaves exactly one valid deploy key and webhook.

It needs `gh` authenticated with `repo` scope (`gh auth status`). If `gh` is missing or logged out the
script stops **before** deleting anything, rather than removing the old key and then failing to add the
replacement. Doing it by hand is still documented in `docs/cicd.md`, "First-time setup runbook",
steps 1 and 4.

---

## If something breaks

- **Step 5 stops with "refusing to build -- the working tree has uncommitted changes" and the only
  change is `terraform/.terraform.lock.hcl`** → **the deploy dirtied its own tree, and this will
  happen again.** Step 2 runs `terraform init -upgrade`, which rewrites that lock file whenever
  HashiCorp has published a newer patch release of any provider since your last deploy. Terraform
  even prints "Review those changes and commit them to your version control system" while it does
  it. A few steps later the image build refuses to run, because images are tagged from
  `git rev-parse --short HEAD` and a dirty tree means the tag would not describe what is in the
  image. **The fix is to commit the lock file and re-run the same command** — check the diff first,
  it should be nothing but version numbers and hashes:

  ```bash
  git diff terraform/.terraform.lock.hcl     # expect only version/hash lines
  git add terraform/.terraform.lock.hcl && git commit -m "chore(terraform): update provider lock"
  VOTEBALL_AUTO_APPROVE=1 scripts/deploy.sh  # steps 1-4 re-run harmlessly, then it continues
  ```

  Do **not** reach for `ALLOW_DIRTY_BUILD=1` here. That exists for a genuinely different case
  (deliberately building work in progress) and it tags the image `<sha>-dirty` forever. A provider
  lock bump is a real change that belongs in git — committing it is the correct outcome, not a
  workaround. Observed 2026-08-17 (`null` 3.3.0→3.3.1, `time` 0.14.0→0.14.1).
- **Step 6 fails with `Kubernetes cluster unreachable ... i/o timeout` on every `helm_release` and
  `kubernetes_*` resource at once** → this is almost never the cluster. Your internet provider gave
  you a new address, and the cluster's API allow-list still names the old one; AWS silently drops the
  packets instead of refusing them, so it reads as "the cluster is down". **`deploy.sh` now fixes this
  itself before it starts** — its preflight adds your current address to
  `terraform/voteball.tfvars` when the list does not already cover you, keeping any broader range
  that is already there. So if you see this, you are looking at an older run (or at
  `terraform apply` run by hand): re-run `./scripts/deploy.sh` and it will correct the list and
  continue. `VOTEBALL_NO_CIDR_FIX=1` turns the fix back into a warning if you would rather edit the
  file yourself. Hit for real on 2026-08-26, after ~13 billed minutes of apply.
- **The first `terraform apply` errors part-way through** → just run `terraform apply` again. Some pieces
  can only install after the cluster exists, so a second run finishes them.
- **The site loads but shows no parties/teams** → this was a bug we already fixed; make sure you're on the
  latest code (`git pull`). (Cause: the app's firewall rules needed to allow the internal "service"
  network, not just the machine network.)
- **The nightly backup fails** → two separate causes, both already fixed in the latest code: it needed
  a writable temp folder, and (until 2026-07-31) its pods were labelled `app: voteball-backup` while
  the NetworkPolicy allowed only `app: backup`, so the upload to S3 was blocked. Make sure you're on
  the latest code. The second one is the more instructive failure: the dump itself always worked, so
  the job looked like a flaky upload rather than a firewall rule — see `charts/voteball/CLAUDE.md`.
- **The nightly backup reports success but the file in S3 is tiny** → that was possible until
  2026-07-31: a failed `pg_dump` still gzipped to a valid ~20-byte archive and the job exited 0.
  `services/backup/backup.sh` now sets `pipefail`, tests the archive, and checks for `pg_dump`'s
  completion trailer before uploading anything. Verify a real backup with
  `aws s3 ls "s3://$(terraform -chdir=terraform output -raw s3_bucket)/backups/" --human-readable` —
  a healthy dump is kilobytes-to-megabytes, not bytes.
- **Teardown prints "These resources were kept due to the resource policy: [CustomResourceDefinition]
  applications.argoproj.io ..."** → harmless. ArgoCD marks those definitions "keep" so an uninstall
  can't delete your app definitions by accident. The whole cluster is deleted moments later, so they
  go with it. Nothing is left behind and nothing is billed.
- **A brief error when a pod restarts** → normal for a second or two while the load balancer notices; the
  site stays up. Real visitors' browsers just retry.
- **"version not supported" style errors on the cluster** → the Kubernetes version pin (`cluster_version`
  in `terraform/variables.tf`, currently `1.36`) may have aged out; check
  `aws eks describe-cluster-versions --region <your region>` and bump it if needed.
- **The site can't be found right after a rebuild** → DNS, and there are **two different causes** —
  flushing your local cache only fixes one of them.
  1. **The ALB is still `provisioning`.** external-dns recreates the record as an *ALIAS* to the load
     balancer, and an alias to a load balancer that isn't `active` yet resolves to **nothing**. Check:
     `aws elbv2 describe-load-balancers --region <your region> --query 'LoadBalancers[].State.Code'`
     — it must say `active`. This clears itself in a few minutes.
  2. **A resolver cached the "no address" answer** during the window in (1) or during teardown. This
     is *upstream* caching, not local — `sudo resolvectl flush-caches` does **not** help if your
     provider's resolver is the one holding it. It expires on its own after
     `min(SOA MINIMUM, SOA record TTL)`, which for a Route53 zone is **15 minutes**.

  Distinguish them by asking the authoritative nameserver directly, which no cache can affect:
  ```bash
  NS=$(aws route53 get-hosted-zone --id <zone-id> --query 'DelegationSet.NameServers[0]' --output text)
  dig +short @"$NS" <your app_domain> A      # authoritative truth
  dig +short @8.8.8.8 <your app_domain> A    # what the world currently sees
  ```
  Authoritative answers but a public resolver doesn't → cache, wait it out. Neither answers → the ALB
  is still provisioning. The signature of a cached negative is `status: NOERROR` with `ANSWER: 0`
  (**not** `NXDOMAIN`): the name exists, its alias target just has no address yet.

  To verify the site itself while DNS is settling, bypass it entirely:
  ```bash
  curl -sI --resolve "<your app_domain>:443:$(dig +short @"$NS" <your app_domain> A | head -1)" \
    https://<your app_domain> | head -1
  ```
  *(All of the above was observed on the 2026-07-27 rebuild: `1.1.1.1` served nothing for ~15 minutes
  while `8.8.8.8`, `9.9.9.9` and `208.67.222.222` were already correct and the site returned 200.)*
- **A deploy fails at step 10 with `conflict with "argocd-controller"`** → two things are trying to
  apply the app at once. Kubernetes tracks *who owns each field*, and it lets two owners share a field
  only while they set it to the **same** value; the moment they disagree, the second one is refused.
  ArgoCD already owns this app, and step 9 has just published a new image version, so Helm asking for
  a different version is exactly that disagreement. **This is expected on any re-run and `deploy.sh`
  now avoids it** — step 10 only uses Helm on a brand-new cluster, and otherwise waits for ArgoCD to
  pick the change up itself. If you hit it running Helm by hand, you don't need to fix anything: the
  deploy is already correct, ArgoCD ships it within a couple of minutes. Watch it land with
  `./scripts/wait-for-argocd-sync.sh`. **Do not reach for `--force-conflicts`** — that takes the app
  away from ArgoCD and hands it to whatever is on your laptop, which is the one situation this whole
  setup exists to prevent.
- **`terraform destroy` sits on "Still destroying... subnet" for many minutes** → a leftover network
  interface from a terminated node is pinning the subnet. `destroy.sh` now cleans these up
  automatically while it runs, and its progress watcher prints the count that is holding things up
  (`network interfaces left  14 (3 detached)`), so you can see it draining rather than guessing; if you hit it in a manual destroy, find and delete the detached one:
  `aws ec2 describe-network-interfaces --region <your region> --filters Name=status,Values=available
  --query "NetworkInterfaces[?starts_with(Description,'aws-K8S-')].NetworkInterfaceId"` then
  `aws ec2 delete-network-interface --region <your region> --network-interface-id <id>`. The subnet
  deletes within seconds afterwards.
- **`terraform destroy` hangs on a `helm_release`** ("context deadline exceeded") → Helm can't cleanly
  uninstall while the cluster is being deleted. Drop it from state and re-run; it dies with the
  cluster anyway: `terraform -chdir=terraform state rm helm_release.<name>`, then
  `./scripts/destroy.sh`.
- **A network (VPC) refuses to delete and nothing obvious is left in it** → look for a **security group
  that Kubernetes created**, not Terraform. A VPC cannot be deleted while any non-default security group
  survives in it, and anything Kubernetes made is invisible to the tool trying to delete around it — so
  the delete retries silently until it gives up, with no error naming the real cause.

  ```bash
  aws ec2 describe-security-groups --region <your region> \
    --filters Name=vpc-id,Values=<vpc-id> \
    --query 'SecurityGroups[?GroupName!=`default`].{name:GroupName,id:GroupId}' --output table
  ```

  Delete any that come back (`aws ec2 delete-security-group --group-id <id>`); the `default` one goes
  automatically with the VPC. This is the same lesson as the leftover network interfaces above, one
  layer up: **when a Kubernetes cluster is deleted, the AWS resources Kubernetes created for it are
  orphaned, not cleaned up.** Delete Services and Ingresses *before* the cluster, which is exactly what
  `destroy.sh` steps 1–2 do and why they cannot be skipped. Observed on 2026-08-02 in an unrelated
  practice cluster, where one such group had blocked its teardown for five weeks — and the load balancer
  it belonged to went on billing the whole time.
- **`values.yaml` looks wrong / the ALB says `CertificateNotFound`** → the file drifted from the live
  stack. Run `./scripts/sync-values-from-tf.sh --check` to see the drift and
  `./scripts/sync-values-from-tf.sh` to fix it. Never edit those fields by hand.
- **For ~15 minutes after a rebuild, webhook deliveries fail intermittently — and a failed `push` is
  lost for good.** GitHub retries pings but **does not retry a failed `push` delivery**, so that commit
  never reaches Jenkins: no build, no error, and `image.tag` on `master` quietly stops matching the
  code. The only trace is a red row in the delivery log.

  **The cause is DNS negative caching, not the load balancer.** Teardown deletes the
  `jenkins.<app_domain>` record (step 5), and while it is missing GitHub's resolvers cache the
  "no address" answer. A Route53 zone pins negative caching at **15 minutes** (`min(SOA MINIMUM, SOA
  TTL)`) — the same figure documented above for the site itself. external-dns recreates the record
  during the rebuild, but the cached negatives outlive it. GitHub sends from a **fleet** of hosts with
  independent resolver caches, which is why the failures are intermittent rather than total: some
  senders still hold the stale negative, others resolve fresh.

  **How to tell this apart from a genuinely broken endpoint — look at `duration`:**

  ```bash
  H=$(gh api repos/<owner>/<repo>/hooks --jq '.[0].id')
  gh api repos/<owner>/<repo>/hooks/$H/deliveries --jq '.[0:8][] | "\(.delivered_at) \(.event) code=\(.status_code) dur=\(.duration)"'
  ```

  A failure at **`dur=0` or `0.01`** never made a network connection — that is a DNS cache miss, and it
  clears itself. A successful delivery takes a realistic round trip (~0.5–0.7 s from the US to
  `il-central-1`). A *genuinely* broken endpoint fails with a **realistic** duration, because the
  connection was attempted and refused. Measured on the 2026-08-03 rebuild: every failure was
  `dur=0.0`–`0.01`, every success `0.53`–`0.66`.

  Replay a lost delivery rather than re-pushing:

  ```bash
  D=$(gh api repos/<owner>/<repo>/hooks/$H/deliveries --jq '[.[] | select(.status_code!=200)][0].id')
  gh api -X POST repos/<owner>/<repo>/hooks/$H/deliveries/$D/attempts
  ```

  **Step 11b's ping check does not rule this out** — it only proves *one* GitHub sender could resolve
  the name at that instant. **After a rebuild, wait ~15 minutes before pushing code**, or check the
  delivery log afterwards and replay anything red.

For the deeper technical details behind these, see the git history of this file and the design documents
in `docs/design/` — in particular `2026-07-20-deployment-hardening-design.md`, which explains why the
deploy and destroy scripts are ordered the way they are and what went wrong before they were.
