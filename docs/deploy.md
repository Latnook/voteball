# Deploy / destroy guide

> **Status:** verified end-to-end against a real deploy on 2026-07-12 —
> infrastructure provisioned, site reachable over HTTPS with a valid cert,
> vote submission → worker rollup → results all confirmed working, and the
> admin Knesset sync pulled real data live. The steps below reflect what
> actually worked, including two fixes discovered during that first deploy
> (see "Known gotchas" at the end).

## Prerequisites

- AWS credentials for the target account, region `il-central-1`.
- `terraform`, `ansible`, `ansible-vault`, `helm`, `ssh-keygen` installed locally.
- The Route 53 hosted zone for `latnook.com` must already exist in the account
  (Terraform reads it as a data source, doesn't create it).

## First-time setup (once per checkout)

```bash
# 1. EC2 key pair (public half is committed; only the private half is generated here)
cd voteball
ssh-keygen -t ed25519 -f Voteball-EC2-pem -N "" -C "voteball-ec2"
mv Voteball-EC2-pem Voteball-EC2-pem.pem
chmod 400 Voteball-EC2-pem.pem

# 2. Terraform variables
cd terraform
cp voteball.tfvars.example voteball.tfvars
# edit voteball.tfvars: ssh_allowed_cidr (curl -s https://checkip.amazonaws.com),
# db_password, notification_email

# 3. Ansible vault password + secrets
cd ../ansible-project
openssl rand -hex 32 > .vault_pass
cp inventories/voteball/group_vars/all/secrets.yml.example \
   inventories/voteball/group_vars/all/secrets.yml
# edit secrets.yml: db_pass (MUST match terraform/voteball.tfvars' db_password),
# admin_secret (openssl rand -hex 32)
ansible-vault encrypt inventories/voteball/group_vars/all/secrets.yml --vault-password-file .vault_pass
```

## Deploy

```bash
# 1. Provision AWS infrastructure
cd terraform
terraform init
terraform plan     # review before applying — this creates billed resources
terraform apply

# 2. Generate the Ansible inventory from live Terraform outputs
cd ..
./scripts/generate-inventory.sh

# 3. Install Docker/k3s on the node and deploy the Helm chart
cd ansible-project
ansible-playbook site-k3s.yml

# 4. Verify
curl -sf https://voteball.latnook.com/api/options
```

Note: `/health` (no `/api/` prefix) is the backend's own liveness/readiness probe
route — Kubernetes hits it directly on the pod's port 5000, in-cluster. It is
**not** reachable externally through nginx, since nginx only proxies paths under
`/api/` and preserves that prefix when forwarding (see `nginx.conf.j2`'s
`proxy_pass http://backend:5000;`, deliberately without a trailing slash so the
`/api/...` prefix survives — a bare `/api/health` would 404 since the backend has
no route by that name). Use `/api/options` as the external smoke test instead.

Re-running `ansible-playbook site-k3s.yml` after a code change re-triggers the
Docker image build/push and `helm upgrade` — it's the normal update path, not
just first-install.

## Destroy

Tear down in the reverse order — Kubernetes resources don't need explicit
cleanup since the whole EC2 node they run on is being deleted:

```bash
cd terraform
terraform destroy
```

This deletes the EC2 instance, RDS database (final snapshot is skipped —
see `terraform/modules/database/main.tf`'s `skip_final_snapshot`, an
intentional choice for this low-stakes, time-boxed poll), Elastic IP,
Route 53 record, IAM role/policy, and SNS topic.

`terraform.tfstate` and `voteball.tfvars` are gitignored and local-only — if
you lose them, `terraform destroy` can't target the right resources and
cleanup has to be done manually via the AWS console/CLI.

## Redeploying after a destroy

`terraform destroy` only deletes AWS resources — it does not touch anything
on your local machine. **Skip "First-time setup" entirely on a redeploy**;
none of it needs to be repeated:

- The SSH key pair, `voteball.tfvars`, `.vault_pass`, and `secrets.yml` all
  still exist on disk exactly as before and get reused as-is.
- The only thing worth double-checking is `ssh_allowed_cidr` in
  `voteball.tfvars` — if your IP changed since the last deploy
  (`curl -s https://checkip.amazonaws.com`), update it before `apply`,
  otherwise you'll provision an instance you can't SSH into.

Just run the **Deploy** steps above again from `terraform apply` onward.
Three things will legitimately be different from before, all handled
automatically — no extra manual steps, just don't be surprised:

- **New public IP.** The Elastic IP is destroyed and recreated, so you'll
  get a different address. `dns.tf` updates the `voteball.latnook.com`
  Route 53 record on `apply` automatically; allow a few minutes for DNS
  propagation (record TTL is 300s).
- **Empty database.** RDS is destroyed with no snapshot (by design — see
  "Destroy" above). The backend recreates its schema automatically on
  first pod start (`db.init_db()` in `app.py`'s `__main__`), so this needs
  no manual step, but all votes and previously-synced party data from the
  prior deploy are gone. Re-run the admin Knesset sync
  (`POST /api/admin/sync-previous-parties`) after redeploying to repopulate
  `previous_parties`.
- **New TLS certificate.** A fresh instance has no `/etc/letsencrypt`, so
  certbot does a full DNS-01 issuance again during the Ansible run (a few
  minutes) rather than reusing/renewing anything.
- **SNS subscription needs reconfirming again.** The SNS topic is
  destroyed and recreated, so today's email confirmation doesn't carry
  over — see "confirm the SNS subscription" below, you'll get a new email.

## After first deploy: confirm the SNS subscription

`terraform apply` creates the milestone-alert email subscription in
`Pending Confirmation` state — check the inbox for `notification_email`
(set in `voteball.tfvars`) and click the confirmation link, or milestone
alerts will silently never arrive. Verify with:

```bash
aws sns list-subscriptions-by-topic --topic-arn "$(cd terraform && terraform output -raw sns_topic_arn)" --region il-central-1
```
`SubscriptionArn` should be a real ARN, not `PendingConfirmation`.

## Known gotchas (found during the first real deploy)

- **Verify `ami_id` before trusting its description.** `terraform/variables.tf`'s
  `ami_id` default was once a mislabeled golden image from an unrelated
  project (its AWS description said "Amazon Linux 2023" but it was actually
  a snapshot of a live app server, complete with that app's code and an
  auto-starting service competing for resources). If you ever change this
  value, verify what you're actually pointing at:
  `aws ec2 describe-images --image-ids <ami> --query 'Images[0].Name'`.
- **`t3.small` can CPU-throttle mid-deploy.** It's a burstable instance;
  Docker+k3s install plus three image builds back-to-back can exhaust its
  credit balance, throttling everything to baseline for the rest of the
  run. The default is `t3.medium` for headroom — cheap insurance
  (~$0.024/hr more) against a deploy that silently crawls for 20+ minutes.
- **Don't run `pytest` inside a `files/<service>/` directory right before
  deploying** without checking for leftover `.venv`/`__pycache__`/
  `.pytest_cache`. The Ansible copy tasks now copy an explicit file list
  (not a whole-directory copy), so stray local artifacts no longer get
  shipped to the server — but it's worth knowing why that safeguard exists.
