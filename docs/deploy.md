# Deploy guide (EKS)

How to put the Voteball site online on AWS, check it works, and take it back down.

**Heads-up:** running this costs real money (~$200/month while it's up). Always take it down when you're
done. Last verified working end-to-end on 2026-07-19.

---

## The two halves of the system (in plain terms)

- **Terraform** builds the AWS side: the Kubernetes cluster, the database, the container registry, the
  load balancer's certificate, etc. Think of it as *building the ground the app stands on*.
- **Helm** installs the Voteball app *onto* that ground: the website, the backend, the worker.

You run Terraform first, then Helm. Taking it down is the reverse.

*(The old single-server "k3s" setup is retired. This guide is the current EKS one.)*

---

## One-time setup

You need these installed: `terraform`, the `aws` command, `kubectl`, `helm`, `docker`. You must be
logged into AWS (`aws sts get-caller-identity` should show account `590183895228`).

Then create one settings file:

```bash
cd terraform-eks
cp voteball-eks.tfvars.example voteball-eks.tfvars
# open voteball-eks.tfvars and set your email:  notification_email = "you@example.com"
cd ..
```

Keep a backup copy of `voteball-eks.tfvars` and, after your first run, `terraform-eks/terraform.tfstate`
(a copy in a password manager is fine). They aren't in git, and losing them means cleaning up AWS by hand.

---

## Put the site online

**Everything, in order:**

```bash
./scripts/deploy.sh
```

It runs the whole sequence and **stops to ask you to confirm** before Terraform creates billed
resources. The steps it performs:

1. Find the newest database snapshot to restore from.
2. Build the AWS infrastructure (**asks you to type `yes`**).
3. Copy the app's passwords into AWS's secret vault (nothing secret is printed or stored in git).
4. Point `kubectl` at the new cluster.
5. Build the four container images and upload them.
6. Fill in `charts/voteball/values.yaml` from the Terraform outputs — the database address, the
   certificate, the bucket, and the IAM roles all change on every rebuild, so **never edit these by
   hand**.
7. Install the app and wait for it to come up.
8. Hand ongoing control to ArgoCD.

If step 6 changed `values.yaml`, commit it — ArgoCD deploys from `master`:

```bash
git add charts/voteball/values.yaml && git commit -m "Deploy: sync values" && git push
```

**Confirm the alert email:** check your inbox for an AWS confirmation link and click it, or the
milestone-alert emails won't arrive.

Give it a few minutes, then open **https://voteball.latnook.com**.

**Later, after changing app code:** just `git push` — CI rebuilds the images and ArgoCD deploys them.
To do it by hand instead, run `./scripts/deploy.sh` again.

---

## Check it worked

```bash
kubectl get pods -n devops-app          # everything should say "Running"
curl -sf https://voteball.latnook.com/api/options | head -c 120   # should print leagues/clubs/parties
```

Open the site in a browser and cast a vote — it should land and show on the results page.

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

---

## If something breaks

- **The first `terraform apply` errors part-way through** → just run `terraform apply` again. Some pieces
  can only install after the cluster exists, so a second run finishes them.
- **The site loads but shows no parties/teams** → this was a bug we already fixed; make sure you're on the
  latest code (`git pull`). (Cause: the app's firewall rules needed to allow the internal "service"
  network, not just the machine network.)
- **The nightly backup fails** → already fixed in the latest code (it needed a writable temp folder).
- **A brief error when a pod restarts** → normal for a second or two while the load balancer notices; the
  site stays up. Real visitors' browsers just retry.
- **"version not supported" style errors on the cluster** → the Kubernetes version pin (`1.34`) may have
  aged out; check `aws eks describe-cluster-versions --region il-central-1` and bump it if needed.
- **The site can't be found right after a rebuild** → DNS. The record is recreated on deploy, but your
  computer may have cached the old answer. Check it works publicly first:
  `dig +short voteball.latnook.com @8.8.8.8` — if that returns addresses, flush your local cache
  (`sudo resolvectl flush-caches`) or try a private browser window.
- **`terraform destroy` sits on "Still destroying... subnet" for many minutes** → a leftover network
  interface from a terminated node is pinning the subnet. `destroy.sh` now cleans these up
  automatically while it runs; if you hit it in a manual destroy, find and delete the detached one:
  `aws ec2 describe-network-interfaces --region il-central-1 --filters Name=status,Values=available
  --query "NetworkInterfaces[?starts_with(Description,'aws-K8S-')].NetworkInterfaceId"` then
  `aws ec2 delete-network-interface --region il-central-1 --network-interface-id <id>`. The subnet
  deletes within seconds afterwards.
- **`terraform destroy` hangs on a `helm_release`** ("context deadline exceeded") → Helm can't cleanly
  uninstall while the cluster is being deleted. Drop it from state and re-run; it dies with the
  cluster anyway: `terraform -chdir=terraform-eks state rm helm_release.<name>`, then
  `./scripts/destroy.sh`.
- **`values.yaml` looks wrong / the ALB says `CertificateNotFound`** → the file drifted from the live
  stack. Run `./scripts/sync-values-from-tf.sh --check` to see the drift and
  `./scripts/sync-values-from-tf.sh` to fix it. Never edit those fields by hand.

For the deeper technical details behind these, see the git history of this file and the plan documents in
`docs/superpowers/plans/`.
