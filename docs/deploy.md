# Deploy / destroy guide

Verified end-to-end against a real deploy (2026-07-12): infra provisioned,
site live over HTTPS, vote → rollup → results confirmed, admin sync
confirmed. `terraform`, `ansible`/`ansible-vault`, `helm`, `ssh-keygen`
required locally. The `latnook.com` Route 53 zone must already exist.

## Setup (once per checkout)

```bash
# 1. EC2 key pair
ssh-keygen -t ed25519 -f Voteball-EC2-pem -N "" -C "voteball-ec2"
mv Voteball-EC2-pem Voteball-EC2-pem.pem
chmod 400 Voteball-EC2-pem.pem

# 2. Terraform variables
cd terraform
cp voteball.tfvars.example voteball.tfvars
# edit: ssh_allowed_cidr (curl -s https://checkip.amazonaws.com), db_password, notification_email
cd ..

# 3. Ansible vault password + secrets
cd ansible-project
openssl rand -hex 32 > .vault_pass
cp inventories/voteball/group_vars/all/secrets.yml.example inventories/voteball/group_vars/all/secrets.yml
# edit secrets.yml: db_pass (must match voteball.tfvars' db_password), admin_username,
# admin_password_hash (generate via ansible-project/roles/backend/files/backend/scripts/hash_admin_password.py),
# admin_session_secret (openssl rand -hex 32)
ansible-vault encrypt inventories/voteball/group_vars/all/secrets.yml --vault-password-file .vault_pass
cd ..
```

**Redeploying an existing installation?** This admin-auth migration is a breaking change: the
backend container now requires `ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH`/`ADMIN_SESSION_SECRET` and no
longer reads `ADMIN_SECRET` at all. Before the next `ansible-playbook` run, edit the real
`secrets.yml` (`ansible-vault edit inventories/voteball/group_vars/all/secrets.yml
--vault-password-file .vault_pass`) to replace `admin_secret` with the three new keys — otherwise the
backend pod will crash-loop on missing env vars.

**Back up these 4 files somewhere other than this disk** (a password manager entry
is enough — they're all small text/key files): `Voteball-EC2-pem.pem`,
`terraform/voteball.tfvars`, `ansible-project/.vault_pass`, and
`terraform/terraform.tfstate` (once it exists, after your first `apply`).
None of them are in git (by design — they're secrets or machine-specific
state) and none of them are recoverable if this machine is lost. In
particular: `.vault_pass` is the only thing that can decrypt `secrets.yml`
— if it's gone, the encrypted file in the repo is permanently unreadable,
no exceptions, and you'd be starting over with new secrets and new infra.

## Deploy

```bash
# 1. Check for a snapshot from a prior destroy (restores it if found, see below)
./scripts/find-latest-snapshot.sh

# 2. Provision AWS infrastructure (billed resources — review the plan first)
cd terraform
terraform init
terraform plan -var-file=voteball.tfvars
terraform apply -var-file=voteball.tfvars
cd ..

# 3. Generate the Ansible inventory from live Terraform outputs
./scripts/generate-inventory.sh

# 4. Install Docker/k3s and deploy the Helm chart
cd ansible-project
ansible-playbook site-k3s.yml
cd ..

# 5. Verify
curl -sf https://voteball.latnook.com/api/options
```

Re-running `ansible-playbook site-k3s.yml` is also the normal update path
after a code change.

Use `/api/options` to verify, not `/api/health` — `/health` is the
in-cluster k8s probe route only, not exposed through nginx.

After the first `apply`, confirm the SNS email subscription (check
`notification_email`'s inbox for a confirmation link) or milestone alerts
won't be delivered:
```bash
cd terraform
TOPIC_ARN=$(terraform output -raw sns_topic_arn)
cd ..
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region il-central-1
```

## Destroy

```bash
cd terraform
terraform destroy -var-file=voteball.tfvars -var="db_final_snapshot_suffix=$(date +%Y%m%d%H%M%S)"
cd ..
```

Deletes everything: EC2, RDS, EIP, Route 53 record, IAM, SNS. RDS takes a
**final snapshot before deleting** (the `-var` above gives it a unique
name so repeated destroys don't collide — don't omit it). Don't lose
`terraform.tfstate` or `voteball.tfvars` (gitignored, local-only) or
you'll be cleaning up by hand.

## Redeploying after a destroy

Just re-run **Deploy** from `find-latest-snapshot.sh` — skip **Setup**
entirely, none of it needs repeating (SSH key, tfvars, vault password,
secrets.yml all still exist locally). Only check that `ssh_allowed_cidr`
still matches your current IP.

`find-latest-snapshot.sh` finds the snapshot from the last destroy and
restores from it automatically — **votes are not lost**. To manage
individual votes instead of wiping the whole database, use the admin
endpoints: `GET /api/admin/votes` to list, `DELETE /api/admin/votes/<id>`
to remove one (both need `X-Admin-Secret`). To force a genuinely empty
database on a specific redeploy instead, delete
`terraform/snapshot.auto.tfvars` before running `terraform apply`.

Expect, automatically, no action needed: a new public IP (DNS updates
itself, allow a few minutes to propagate) and a fresh TLS cert issuance.

## Gotchas

- **Check `ami_id` is actually what its description claims** before trusting
  it (`aws ec2 describe-images --image-ids <ami> --query 'Images[0].Name'`) —
  we once inherited a mislabeled AMI that was secretly a different project's
  server image.
- **`t3.small` can CPU-throttle mid-deploy** (burstable instance, credits
  exhausted by Docker+k3s install + 3 image builds). Default is `t3.medium`.
- Ansible copies an **explicit file list** for the backend/worker build
  contexts, not a whole directory — so a stray local `.venv` from running
  `pytest` won't get shipped to the server.
- **The snapshot/restore mechanism (added 2026-07-12) hasn't been exercised
  through a real destroy→apply cycle yet** — `terraform validate` passes and
  the "no snapshot exists" path is confirmed against real AWS, but the
  actual restore-from-snapshot path will get its first real test on your
  next destroy/redeploy. If it doesn't work as expected, `snapshot_identifier`
  is in `lifecycle.ignore_changes` on the RDS resource (`terraform/modules/database/main.tf`)
  specifically so a bad restore doesn't force-replace the DB on a later
  unrelated `apply` — worth knowing if you need to debug it.
