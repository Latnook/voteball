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
# edit secrets.yml: db_pass (must match voteball.tfvars' db_password), admin_secret (openssl rand -hex 32)
ansible-vault encrypt inventories/voteball/group_vars/all/secrets.yml --vault-password-file .vault_pass
cd ..
```

## Deploy

```bash
# 1. Provision AWS infrastructure (billed resources — review the plan first)
cd terraform
terraform init
terraform plan
terraform apply
cd ..

# 2. Generate the Ansible inventory from live Terraform outputs
./scripts/generate-inventory.sh

# 3. Install Docker/k3s and deploy the Helm chart
cd ansible-project
ansible-playbook site-k3s.yml
cd ..

# 4. Verify
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
terraform destroy
cd ..
```

Deletes everything: EC2, RDS (no snapshot — intentional, low-stakes poll
data), EIP, Route 53 record, IAM, SNS. Don't lose `terraform.tfstate` or
`voteball.tfvars` (gitignored, local-only) or you'll be cleaning up by hand.

## Redeploying after a destroy

Just re-run **Deploy** from `terraform apply` — skip **Setup** entirely,
none of it needs repeating (SSH key, tfvars, vault password, secrets.yml
all still exist locally). Only check that `ssh_allowed_cidr` still matches
your current IP.

Expect, automatically, no action needed: a new public IP (DNS updates
itself, allow a few minutes to propagate), an empty database (schema
recreates itself on first pod start — re-run the admin Knesset sync
afterward to repopulate parties), a fresh TLS cert issuance, and a new SNS
confirmation email to click.

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
