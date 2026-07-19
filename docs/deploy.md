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

Do these in order. Each block says what it does.

**1. Build the AWS infrastructure** (~15–20 min — it makes the cluster, database, registry, etc.):

```bash
cd terraform-eks
terraform init
terraform apply -var-file=voteball-eks.tfvars     # it shows a list and asks you to type "yes"
cd ..
```

**2. Put the app's passwords into AWS's secret vault** (nothing secret ever goes in the code):

```bash
./scripts/seed-eks-secret.sh
```

That's it — the script copies the app's passwords (database + admin login) from the project's encrypted
secrets file straight into AWS, without ever showing them. You don't type any passwords.

**3. Connect your computer to the cluster:**

```bash
aws eks update-kubeconfig --name voteball --region il-central-1
```

**4. Build the app's containers and upload them, then point the app at them:**

```bash
./scripts/build-push-ecr.sh        # builds the 4 images and prints a code like "a1b2c3d"
# open charts/voteball/values.yaml and set:  image.tag: "a1b2c3d"   (the printed code)
```

**5. Tell the app where the database is:**

```bash
terraform -chdir=terraform-eks output -raw rds_endpoint    # prints an address ending in rds.amazonaws.com
# open charts/voteball/values.yaml and set:  config.DB_HOST: "<that address>"
```

**6. Install the app:**

```bash
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
```

**7. Confirm the alert email:** check your inbox for an AWS confirmation link and click it (otherwise the
milestone-alert emails won't arrive).

Give it a few minutes, then open **https://voteball.latnook.com** — the site should be live.

**Later, after changing app code:** repeat step 4 (rebuild + set the new code in `values.yaml`), then run
step 6 again.

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
helm uninstall voteball -n devops-app             # removes the app (and its load balancer)
cd terraform-eks
terraform destroy -var-file=voteball-eks.tfvars   # removes the cluster, database, everything
cd ..
```

Note: the EKS database is a throwaway copy, so votes cast while on EKS are **not** saved when you
destroy. (The original vote data lives in an AWS snapshot and is restored automatically next time you
build.)

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

For the deeper technical details behind these, see the git history of this file and the plan documents in
`docs/superpowers/plans/`.
