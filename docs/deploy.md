# Deploy / destroy guide

> **Status:** drafted from the implementation plan; not yet verified against a real
> deploy. Once the first live deployment (Task 21) succeeds, this note is removed
> and any step that turned out to need correction is fixed in place.

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
