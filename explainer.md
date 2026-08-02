# Voteball — how the deployment works

A walkthrough of how this application gets from a git repository onto the internet, and back off
again. Written to be read aloud: each section answers one question, in order.

Voteball itself is a public poll correlating football fandom with Israeli political-party voting.
That is the *subject*; this document is about the *machinery* around it.

---

## 1. The one-sentence version

Terraform builds the AWS infrastructure, a Helm chart describes the application, ArgoCD keeps the
cluster matching what is in git, and Jenkins rebuilds the container images whenever code is pushed —
with the whole thing reproducible from an empty AWS account by running two scripts.

---

## 2. What is actually running

Three containers in a Kubernetes cluster on **Amazon EKS**, in the namespace `devops-app`:

| Container | What it does |
|---|---|
| **frontend** | nginx serving plain HTML/CSS/JavaScript — no build step, no framework. It forwards `/api/*` to the backend. |
| **backend** | A Flask application. All the HTTP routes live in `app.py`, all the SQL in `queries.py`. |
| **worker** | A background loop that recalculates the results tables and sends alerts. |

Behind them sits **PostgreSQL on RDS**, Amazon's managed database service.

The interesting design decision is in the worker. Recalculating results is expensive, so the naive
options are both bad: recalculate on every vote (doesn't scale) or recalculate on a timer (results
are stale). Instead, the backend sends a PostgreSQL `NOTIFY` inside the same transaction that records
the vote, and the worker is blocked on `LISTEN` waiting for it. Results refresh about a second after
a vote instead of up to thirty. A timer still runs underneath as a backstop in case a notification is
missed, and a one-second debounce coalesces bursts of votes into a single recalculation.

**Why pre-computed tables at all?** The database stores raw votes, and separately stores eight
"rollup" tables that the worker maintains. The website reads only the rollups, so a page load is a
simple lookup rather than an aggregation across every vote ever cast. This is the classic trade:
spend work on write so reads are cheap, because the results page is read far more often than a vote
is cast.

---

## 3. The two halves, and why the split matters

This is the central idea of the whole design. Everything divides into two categories, managed by two
different tools, changed in two different ways:

|  | **Infrastructure** | **Application** |
|---|---|---|
| What | VPC, EKS cluster, nodes, RDS, load balancer, certificates, IAM roles, and every platform add-on | The three containers, their config, networking rules, autoscaling |
| Tool | **Terraform** | **Helm**, delivered by **ArgoCD** |
| Changed by | running `terraform apply` | committing to `master` |

The rule that follows: **a change to the application reaches the cluster by pushing to git. A change
to the infrastructure reaches it by running Terraform.** Committing a change to the Jenkins
configuration and walking away does nothing at all — Jenkins is infrastructure, so it needs an apply.

Terraform manages not just the raw AWS resources but every platform add-on too: the load balancer
controller, the secrets operator, the autoscaler, DNS automation, monitoring, ArgoCD itself, and
Jenkins. That is deliberate — those pieces have to exist *before* the application can be deployed, so
they cannot be delivered by the same mechanism that delivers the application.

---

## 4. Putting it online: the eleven steps

`./scripts/deploy.sh` runs these in order. The ordering is the script's real content — almost every
step is placed where it is because putting it elsewhere caused a real failure at some point.

**Steps 1–5: everything cheap, before anything expensive.**

1. **Find the newest database snapshot.** The next step will restore from it. If none exists, it
   writes "none" rather than failing, so a first-ever deploy creates an empty database instead of
   erroring on a missing snapshot.
2. **Create the image registries and empty secret containers** — a small, targeted Terraform run,
   not the full one.
3. **Seed the application credentials** into AWS Secrets Manager.
   **3b. Seed the Jenkins credentials**, and generate a GitHub deploy key and webhook secret.
4. **Mirror the vulnerability-scanner database** into our own registry, so builds don't depend on a
   third-party site being up.
5. **Build and push the Jenkins image.**

**Step 6: the expensive one**, and by far the biggest — a single `terraform apply` that builds around
**117 resources** in roughly thirteen minutes. It is worth knowing what is inside it, because "build
the infrastructure" hides a lot:

| Inside step 6 | What it is |
|---|---|
| VPC, subnets, route tables, gateways | the private network, split into public / private / database-only tiers |
| NAT gateway | lets private nodes reach the internet without being reachable from it |
| **EKS control plane** | the Kubernetes API itself — one of the two long poles |
| **RDS restored from snapshot** | the database, *and the point where your data comes back* — the other long pole |
| Spot node group | the machines that actually run the containers |
| ACM certificates ×2 | HTTPS for the site and for the Jenkins webhook, validated through DNS |
| WAF, SNS, S3, Secrets Manager | firewall, alert emails, backup storage, secret containers |
| **Ten Helm add-ons** | see below — about a third of the total time |
| 2 EKS add-ons | VPC CNI (pod networking), CloudWatch Container Insights |

The **ten Helm add-ons** are the part most people don't realise is here. None of them are the
application; they are the platform the application needs to exist at all:

| Add-on | Why it must exist first |
|---|---|
| AWS Load Balancer Controller | turns a Kubernetes Ingress into a real AWS load balancer |
| External Secrets Operator | copies secrets out of AWS Secrets Manager into the cluster |
| external-dns | writes the Route53 records pointing at the load balancer |
| Cluster Autoscaler | adds nodes when the cluster runs out of room |
| metrics-server | supplies the CPU numbers the autoscaler for pods reads |
| Node Termination Handler | drains a Spot node gracefully before AWS reclaims it |
| kube-prometheus-stack | Prometheus, Grafana and Alertmanager |
| ArgoCD | the GitOps controller that will deploy the application |
| Jenkins + Jenkins support | CI, running in the cluster |

This is the concrete meaning of the earlier "Terraform owns the platform, ArgoCD owns the
application" split. Every row above has to be running *before* the application can be installed —
which is why they cannot be delivered by the mechanism that delivers the application.

### Why step 6 is one command and not six

It is tempting to split something this large into stages you can watch. Doing so would make it
**slower**, for a reason worth understanding.

Measured on a real rebuild: the EKS control plane took **7 m 51 s** and the RDS restore took
**7 m 56 s** — but that phase of the deploy took **about eight minutes, not sixteen**. Terraform works
out from the dependency graph that the two are independent and starts both at once. The same happens
with the add-ons: seven Helm releases of two to four minutes each finish in about four minutes total.

So step 6's thirteen minutes contains roughly **thirty minutes of serial work**. Splitting it into
targeted stages would force that work back into a queue. There is also a specific trap: Terraform's
`-target` flag prunes the dependency graph to just what you asked for, and *silently omits outputs
that live outside it* — a real bug this project hit, where a targeted run appeared to succeed and the
next step failed with a missing registry address.

**The right fix for "I can't see what's happening" is better reporting, not smaller commands.** The
wall-clock cost of a deploy is the longest dependency chain, not the sum of the parts — and that is
the single biggest practical advantage of declarative infrastructure over a shell script. A script
does what you wrote, in the order you wrote it. Terraform works out what can happen at the same time
and does that instead.

**Steps 7–11: the application.** Point `kubectl` at the new cluster; build and push the four
application images tagged with the current git commit; write the new infrastructure's addresses into
the Helm chart's values; commit and push that file; install the chart; and finally hand control to
ArgoCD.

### Three orderings worth being able to explain

**Why the credentials are seeded at step 3, before the big apply at step 6.** The secrets operator
copies a secret from AWS into the cluster *once when it is created*, and then only every hour. Step 6
creates both Jenkins and that copy mechanism together. So if you seeded afterwards, the first copy
would capture an empty placeholder: Jenkins would boot with no administrator account and reject every
login for up to an hour — while the deploy reported complete success throughout.

**Why everything that needs a human answer is collected at the very top.** The script asks for
passwords before step 1, not at step 3 where they are used. Otherwise a typo or a missing value fails
*after* a fifteen-minute billed run rather than before it.

**Why `values.yaml` is committed at step 9, before ArgoCD is started at step 11.** ArgoCD deploys
what is on `master`, not what is on your disk. Start it while that file is uncommitted and it
immediately "corrects" the cluster back to the previous image tag — which, after a rebuild, names an
image that no longer exists, so every container fails to start.

That last one is the general lesson of GitOps and worth stating plainly: **once ArgoCD is running, git
is the truth and the cluster is a copy.** Anything you change directly in the cluster gets reverted.

---

## 5. Taking it down: six steps, and why order is everything

`./scripts/destroy.sh`. This is the part most worth explaining, because every step exists to prevent
a specific failure.

1. **Delete the ArgoCD application first.** ArgoCD's job is to put back anything that disappears. Skip
   this and it fights the teardown, recreating what you delete.
2. **Delete both Ingresses** — the site's and Jenkins'. They share one load balancer, and a shared
   load balancer is only released when *nothing* is using it. Deleting one leaves it running.
3. **Wait for the load balancer to actually disappear.**
4. **Uninstall the application.**
5. **Remove the DNS records.**
6. **Then** destroy the infrastructure.

### The dependency problem this is really about

Steps 2 and 3 exist because of a mismatch in how AWS works. A load balancer is not one thing — it is a
load balancer *plus* a network interface in each subnet it spans. Deleting a subnet is **synchronous**
and fails immediately if any network interface is attached. Deleting a load balancer is
**asynchronous** — AWS accepts the request and does the work later.

So Terraform can be entirely correct about the order and still fail: it deleted the load balancer, AWS
said "accepted", and thirty seconds later the network interfaces are still there. Step 3 converts an
asynchronous operation into a synchronous one that the following steps can rely on.

There is a second version of the same problem. When Kubernetes nodes shut down, the networking plugin
sometimes leaves detached network interfaces behind. Terraform has no way to wait for these, because
it never created them — Kubernetes did, at runtime. So the script runs a small background loop during
the teardown that deletes any interface which is both *detached* and *created by the networking
plugin*. Both conditions matter: a detached one is garbage by definition, and anything still in use
reports a different status and is never touched.

**The general principle, and the most valuable thing in this document:** when a Kubernetes cluster is
deleted, the AWS resources Kubernetes created for it are *orphaned, not cleaned up*. Kubernetes made
them; the tool deleting the cluster doesn't know they exist. That is why Services and Ingresses must be
deleted *before* the cluster, and it is exactly what steps 1–3 are doing.

### What survives on purpose

Three things are deliberately never deleted:

- **The Terraform state bucket** — it holds the record of what is being deleted. Destroying it
  mid-teardown would leave resources running that nothing knows about.
- **A final database snapshot**, taken automatically, so a rebuild restores the votes.
- **Retained automated backups.**

One thing that does *not* survive and surprises people: the nightly database dumps stored in S3 are
deleted along with their bucket, during the same run they would supposedly be insuring. They are
useful day-to-day; they are not teardown insurance.

---

## 6. How code reaches production

Jenkins runs **inside the cluster**, in its own namespace, installed by Terraform. Pushing application
code to `master` triggers:

**GitHub webhook → guard → build → security scan → push to registry → update image tag → ArgoCD deploys**

Three details worth mentioning:

**The guard stage.** Jenkins has no equivalent of "skip this build" markers. At the end of a build the
pipeline commits the new image tag back to `master` — which fires the webhook again, which starts
another build, which commits again, forever. The guard stage is the only thing preventing an infinite,
billable build loop. It looks like dead weight; it is the opposite.

**Builds are rootless.** Building container images normally requires privileged access, which on a
shared cluster is a serious risk. This uses a rootless builder instead, running as an unprivileged
user with no access to the host.

**Jenkins keeps nothing.** Its home directory is temporary storage, not a disk. That sounds like a
mistake and is deliberate: the nodes are all Spot instances, reclaimed by AWS roughly daily. A real
disk in AWS is locked to one availability zone, so every restart would have to land back in the same
zone or the whole thing hangs forever waiting. At a daily restart rate that preserves almost nothing
while adding the one failure mode that needs a human. All configuration comes from a file in git and
is reapplied on every start, and the durable record of what was built is the commits on `master`,
which never expire.

---

## 7. Security posture

Worth being able to list:

- **Every application container runs as a non-root user**, cannot gain privileges, drops all Linux
  capabilities, and has a **read-only filesystem** — with a small writable scratch area only where
  something genuinely needs to write.
- **No secret is ever in git or in Terraform's state file.** Terraform creates *empty* secret
  containers; the values are written separately by a script and copied into the cluster by an
  operator. Passwords are hashed before storage — after seeding, not even AWS can reveal them.
- **Least-privilege cloud access.** Only the worker and the backup job hold AWS permissions, each
  scoped to exactly one action. The frontend and backend hold none at all. Nothing has administrator
  rights.
- **Every image is scanned for vulnerabilities** before it can be deployed.
- **The database is unreachable from the internet** — it sits in isolated subnets with no route out.
- Traffic arrives over HTTPS via a certificate AWS renews automatically, behind a web application
  firewall.

---

## 8. Design principles this project actually follows

**The project is designed to be forkable.** No account number, region or domain is written into the
Terraform, the scripts or the application code — identity lives in one settings file before the deploy,
and in Terraform's outputs after it.

There is **one deliberate exception, and it is worth being able to defend**: the Helm chart's
`values.yaml` holds ten real, environment-specific values — this account's registry address, database
endpoint, certificate and role identifiers — committed to git. That looks like exactly the thing the
rest of the design avoids. It is required, because **ArgoCD deploys what is on `master`, not what is on
someone's laptop.** Placeholders there would mean the cluster syncing placeholders. A script regenerates
those ten fields from Terraform's outputs after every rebuild, and a `--check` mode fails if they have
drifted — so they are *generated and verified*, never hand-edited. Someone forking the project runs that
script rather than editing the file.

This is a genuine trade-off rather than an oversight: GitOps requires the deployed configuration to be
in git, which necessarily puts environment-specific values there. The mitigation is that none of them
are secret — they are addresses and identifiers, not credentials. Every actual secret goes to AWS
Secrets Manager and never enters git or Terraform's state file.

**The reasoning lives in documentation, not code comments.** Design documents record *why* each
decision was made, and several record what actually broke when the design met reality.

**Failure modes are prevented, not just handled.** The repeating pattern is that a failure happened
once, was diagnosed, and then a step was added to make it structurally impossible — the wait loop, the
interface cleaner, the credential ordering, the build guard. The scripts are, in effect, a written
record of everything that has gone wrong.

**Anything unattended must fail cheaply.** Every check that can run before the expensive step does run
before it.

---

## 9. What a full rebuild looks like in practice

Measured on 2026-08-03, tearing down and rebuilding the whole stack:

| Phase | Time |
|---|---|
| Delete ArgoCD app, both Ingresses, load balancer, DNS | 41 seconds |
| `terraform destroy` — 128 resources | 11 minutes 31 seconds |
| **Full teardown** | **~12 minutes** |

The teardown completed with no stuck resources: the load balancer released in about 25 seconds, the
background interface-cleaner caught its one orphan *before* Terraform reached the subnets, and none of
the ten platform components hung on uninstall. The final database snapshot completed and the votes
carried across.

The rebuild takes roughly 30–45 minutes, most of it the cluster and database being created.

---

## 10. If you are asked one question, it will be this one

> *"Why is the order of the teardown script so important?"*

Because AWS resources have dependencies that are not visible from the tool doing the deleting, and
because deletion is asynchronous while the checks are synchronous. A load balancer holds network
interfaces that block subnet deletion; a Kubernetes-created security group blocks the deletion of the
network it lives in; and a tool that only knows about resources *it* created cannot clean up resources
that *Kubernetes* created. Delete in the wrong order and the teardown appears to hang for twenty
minutes, then fails — leaving expensive resources running that nothing is tracking any more.

The script encodes the correct order so that nobody has to remember it.
