# Deploy guide (EKS)

How to put the Voteball site online on AWS, check it works, and take it back down.

**Heads-up:** running this costs real money (~$200/month while it's up). Always take it down when
you're done. Last verified end-to-end on 2026-07-20 (full destroy + rebuild).

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
resources. The steps it performs:

1. Find the newest database snapshot to restore from.
2. Create the Terraform state bucket if it does not exist, then build the AWS infrastructure
   (**asks you to type `yes`**). This now also creates the WAF that rate-limits `/api/vote`.
3. Copy the app's passwords into AWS's secret vault (nothing secret is printed or stored in git).
   The database password is read straight from `voteball.tfvars` (the same file Terraform used in
   step 2, so the two can't disagree); only the **admin** password is asked for — up front, before
   step 2. Run `deploy.sh` in a real terminal — see the note below.
4. Point `kubectl` at the new cluster.
5. Build the four container images and upload them.
6. Fill in `charts/voteball/values.yaml` from the Terraform outputs — the database address, the
   certificate, the WAF, the bucket, and the IAM roles all change on every rebuild, so **never edit
   these ten fields by hand**.
7. Install the app and wait for it to come up. A short-lived migration Job applies the database
   schema **once** before the app pods start, rather than every replica racing to do it.
8. Hand ongoing control to ArgoCD.

Step 6 commits and pushes `values.yaml` for you, because ArgoCD deploys from `master` and not from
this laptop. You don't need to do anything.

### Run it in a real terminal

Right at the start — **before Terraform builds anything billed** — the script asks for your admin
password on screen (nothing is echoed), then runs the rest unattended. (The database password isn't
asked for at all; it's read from `voteball.tfvars`.) Asking up front is deliberate: a missing
password fails in seconds, not after a ~15-minute billed `terraform apply`. That also means
**`deploy.sh` cannot run in a window that has no keyboard attached** — a script, a cron job, or a
tool running it in the background. There it stops with:

```
ERROR: no terminal is attached, and DB_PASS / ADMIN_PASSWORD are not set.
```

That is the script refusing to continue rather than saving a blank password. To run it without a
keyboard, supply the admin password up front instead (the database password still comes from
`voteball.tfvars`, but you can override it here too):

```bash
ADMIN_USERNAME=admin ADMIN_PASSWORD='...' VOTEBALL_AUTO_APPROVE=1 ./scripts/deploy.sh
```

`VOTEBALL_AUTO_APPROVE=1` skips Terraform's "type yes" prompt. On its own it is **not** enough to
make the deploy unattended — without `ADMIN_PASSWORD` it still stops before step 2.

**Re-running `deploy.sh` after a failure is safe, with one catch:** step 3 runs again every time and
issues a new admin session key, which signs out anyone logged into the admin page. Nothing breaks and
your password still works — you just log in again.

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

## Look at the dashboards (Grafana, Prometheus)

Grafana and Prometheus are installed, but **on purpose they are not on the internet** — there is no
web address for them. You open a private tunnel from your own machine instead. Run one of these and
leave it running, then open the link:

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

In Prometheus, **Status → Rule Health** lists the alert rules. If your rules are missing there, they
are not being checked at all — see `charts/voteball/prometheusrule.yaml` for the label that causes
this.

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

**Three things `destroy.sh` deliberately does NOT delete**, and none should be added to it:

| Kept | Why |
|---|---|
| The Terraform **state bucket** | It holds the record of what is being deleted. Removing it mid-teardown would orphan anything left behind. |
| The **Jenkins stack** (`terraform/jenkins/`) | A CI server owned by the stack it builds for would lose its config and history on every rebuild. Stop the instance to save money; don't destroy it. |
| **Database snapshots** | They are the restore point for the next deploy. Prune old ones by hand, keeping the newest. |

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
- **The site can't be found right after a rebuild** → DNS. The record is recreated on deploy, but your
  computer may have cached the old answer. Check it works publicly first:
  `dig +short <your app_domain> @8.8.8.8` — if that returns addresses, flush your local cache
  (`sudo resolvectl flush-caches`) or try a private browser window.
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
