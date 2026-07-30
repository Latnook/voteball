# Deploy guide (EKS)

How to put the Voteball site online on AWS, check it works, and take it back down.

**Heads-up:** running this costs real money (~$200/month while it's up). Always take it down when
you're done. Last verified end-to-end on 2026-07-27 (full destroy + rebuild, with the vote count
unchanged either side — raw captures in [`docs/eks/evidence/`](eks/evidence/)).

---

## The two halves of the system (in plain terms)

- **Terraform** builds the AWS side: the Kubernetes cluster, the database, the container registry, the
  load balancer's certificate, etc. Think of it as *building the ground the app stands on*.
- **Helm** installs the Voteball app *onto* that ground: the website, the backend, the worker.

You run Terraform first, then Helm. Taking it down is the reverse.

*(The old single-server "k3s" setup is retired. This guide is the current EKS one.)*

---

## One-time setup

You need these installed: `terraform`, the `aws` command, `kubectl`, `helm`, `docker`, `python3` and
`openssl`. You must be logged into AWS (`aws sts get-caller-identity` should show your account), and you
need a **Route53 hosted zone you already own** — the deploy looks it up, it never creates one.

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
2. Create the ECR repositories with a small, targeted Terraform apply — before the main build below,
   because the Jenkins install later in this sequence needs somewhere to pull its own image from.
3. Mirror the Trivy vulnerability database into ECR, so the CI pipeline never has to pull it from the
   internet during a build.
4. Build and push the Jenkins controller image (CI now runs inside the cluster; see
   [Connect to each part](#connect-to-each-part-dashboards-argocd-jenkins-the-database) below).
5. Build the rest of the AWS infrastructure (**asks you to type `yes`**) — the cluster, the database,
   the WAF that rate-limits `/api/vote`, and Jenkins itself as a platform add-on alongside ArgoCD and
   the other controllers.
6. Copy the app's passwords into AWS's secret vault (nothing secret is printed or stored in git). The
   database password is read straight from `voteball.tfvars` (the same file Terraform used in step 5,
   so the two can't disagree); only the **admin** password is asked for — up front, before step 5. Run
   `deploy.sh` in a real terminal — see the note below.
7. Copy Jenkins' own credentials (a GitHub deploy key, a webhook secret, an admin login) into AWS's
   secret vault the same way. Also asked for up front, same reason.
8. Point `kubectl` at the new cluster.
9. Build the four app container images and upload them.
10. Fill in `charts/voteball/values.yaml` from the Terraform outputs — the database address, the
    certificate, the WAF, the bucket, and the IAM roles all change on every rebuild, so **never edit
    these ten fields by hand**.
11. Install the app and wait for it to come up, then hand ongoing control to ArgoCD. A short-lived
    migration Job applies the database schema **once** before the app pods start, rather than every
    replica racing to do it.

Step 10 commits and pushes `values.yaml` for you, because ArgoCD deploys from `master` and not from
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
make the deploy unattended — without the other four it still stops before step 5.

**Re-running `deploy.sh` is safe, but step 6 reseeds the admin secret every run — two things follow
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
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana      3000:80    # http://localhost:3000
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus   9090:9090  # http://localhost:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093  # http://localhost:9093
```

Grafana's username is `admin`. Its password is generated fresh at install time (deliberately — a
fixed one would have to be written down in the repo), so **it is different after every rebuild**.
Print the current one with:

```bash
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Prometheus and Alertmanager have **no login at all**. That is on purpose, not an oversight: the only
way to reach them is to already hold cluster access, so a second password would protect nothing and
would have to be stored somewhere.

Where to look once you're in:

- **Grafana** → Dashboards → the `kube-prometheus-stack` folder → *Kubernetes / Compute Resources /
  Namespace (Pods)*, filtered to `devops-app`. That's the app's real CPU and memory use.
- **Prometheus** → **Status → Rule Health** lists the alert rules. If your rules are missing there,
  they are not being checked at all — see `charts/voteball/templates/prometheusrule.yaml` for the
  label that causes this. `kubectl get prometheusrules` would still look perfectly fine.
- **Alertmanager** → the front page shows what is firing *after* grouping, which is the real answer
  to "would this have emailed me?"

### ArgoCD

Same idea, but it speaks HTTPS, so your browser will warn about the certificate — that's expected:

```bash
kubectl port-forward -n argocd svc/argocd-server 8081:443     # then https://localhost:8081
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

Username is `admin`. If you only want to know whether the cluster matches git, you don't need the UI:

```bash
kubectl get applications -n argocd      # "Synced / Healthy" is the answer
```

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
accepts connections from the cluster's own machines. There is no tunnel from your laptop to it. To
get a database prompt, borrow a temporary pod inside the cluster:

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
| Port-forward says the service doesn't exist | A chart upgrade renamed it — run `kubectl get svc -n monitoring` and use the real name |
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

1. **The ArgoCD app first** — otherwise ArgoCD notices the app disappearing and puts it straight back.
2. **The Ingress next** — this releases the load balancer and cleans up the DNS record. A leftover
   load balancer keeps network interfaces alive that block the network from being deleted.
3. **Wait** for the load balancer to actually disappear.
4. **Then** delete everything else.

A final database snapshot is taken automatically, so the next `./scripts/deploy.sh` restores your
votes. (This changed on 2026-07-20 — teardown used to discard them.)

**Two things `destroy.sh` deliberately does NOT delete**, and neither should be added to it:

| Kept | Why |
|---|---|
| The Terraform **state bucket** | It holds the record of what is being deleted. Removing it mid-teardown would orphan anything left behind. |
| **Database snapshots** | They are the restore point for the next deploy. Prune old ones by hand, keeping the newest. |

Jenkins is **not** in this list any more — it is part of the same stack as the app now (namespace `ci`,
installed by the same `terraform apply`), so `terraform destroy` removes it along with everything else.
There is nothing left to keep running between sessions: its credentials live in Secrets Manager, its
configuration lives in git as JCasC, and its build history was already designed to be disposable (see
`docs/cicd.md`) — none of that is lost by tearing the cluster down.

---

## If something breaks

- **The first `terraform apply` errors part-way through** → just run `terraform apply` again. Some pieces
  can only install after the cluster exists, so a second run finishes them.
- **The site loads but shows no parties/teams** → this was a bug we already fixed; make sure you're on the
  latest code (`git pull`). (Cause: the app's firewall rules needed to allow the internal "service"
  network, not just the machine network.)
- **The nightly backup fails** → already fixed in the latest code (it needed a writable temp folder).
- **Teardown prints "These resources were kept due to the resource policy: [CustomResourceDefinition]
  applications.argoproj.io ..."** → harmless. ArgoCD marks those definitions "keep" so an uninstall
  can't delete your app definitions by accident. The whole cluster is deleted moments later, so they
  go with it. Nothing is left behind and nothing is billed.
- **A brief error when a pod restarts** → normal for a second or two while the load balancer notices; the
  site stays up. Real visitors' browsers just retry.
- **"version not supported" style errors on the cluster** → the Kubernetes version pin (`1.34`) may have
  aged out; check `aws eks describe-cluster-versions --region <your region>` and bump it if needed.
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
- **`terraform destroy` sits on "Still destroying... subnet" for many minutes** → a leftover network
  interface from a terminated node is pinning the subnet. `destroy.sh` now cleans these up
  automatically while it runs; if you hit it in a manual destroy, find and delete the detached one:
  `aws ec2 describe-network-interfaces --region <your region> --filters Name=status,Values=available
  --query "NetworkInterfaces[?starts_with(Description,'aws-K8S-')].NetworkInterfaceId"` then
  `aws ec2 delete-network-interface --region <your region> --network-interface-id <id>`. The subnet
  deletes within seconds afterwards.
- **`terraform destroy` hangs on a `helm_release`** ("context deadline exceeded") → Helm can't cleanly
  uninstall while the cluster is being deleted. Drop it from state and re-run; it dies with the
  cluster anyway: `terraform -chdir=terraform state rm helm_release.<name>`, then
  `./scripts/destroy.sh`.
- **`values.yaml` looks wrong / the ALB says `CertificateNotFound`** → the file drifted from the live
  stack. Run `./scripts/sync-values-from-tf.sh --check` to see the drift and
  `./scripts/sync-values-from-tf.sh` to fix it. Never edit those fields by hand.

For the deeper technical details behind these, see the git history of this file and the design documents
in `docs/design/` — in particular `2026-07-20-deployment-hardening-design.md`, which explains why the
deploy and destroy scripts are ordered the way they are and what went wrong before they were.
