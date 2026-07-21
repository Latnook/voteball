# Jenkins build host

A **separate Terraform stack with its own state**, applied and destroyed independently of
`terraform/`.

## Why it is separate

`scripts/destroy.sh` tears down the application stack on every rebuild cycle. A CI server owned by
that stack would be deleted — along with its build history and configuration — every time. This stack
also has **no reference to the main one**: its ECR permission is an ARN pattern, so it applies cleanly
while the cluster is destroyed.

## Apply

```bash
ssh-keygen -t ed25519 -f ~/.ssh/voteball-jenkins -C voteball-jenkins   # once
cp jenkins.tfvars.example jenkins.tfvars                               # fill in admin_cidr
../../scripts/bootstrap-tf-backend.sh                                  # once per account
terraform init -backend-config=backend.hcl
terraform apply -var-file=jenkins.tfvars
```

State lives in S3 under the key `voteball/jenkins.tfstate` — the same bucket as the main stack, a
different key, so the two states and their locks stay independent. `backend.hcl` is **generated and
gitignored** (it names a bucket containing the AWS account id); a `terraform init` without
`-backend-config=backend.hcl` fails on incomplete backend configuration rather than quietly using
local state.

`admin_cidr` is your home IP as a `/32` (`curl -s https://checkip.amazonaws.com`). Update it and
re-apply when your ISP reassigns you.

## Reach the UI

The Jenkins UI is **not publicly reachable**. Only GitHub's webhook CIDRs can reach port 8080.

```bash
terraform output -raw ssh_tunnel_command   # then browse http://localhost:8080
```

## Cost

About **$37/month** running (t3.medium in `il-central-1`). Stop it between sessions:

```bash
aws ec2 stop-instances  --instance-ids "$(terraform output -raw instance_id)"
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
```

Stopped costs about **$6/month** — ~$2.40 for the 30 GB gp3 volume plus ~$3.60 for the Elastic IP,
which AWS bills whether or not the instance is running. All Jenkins state persists on the volume and the Elastic IP
keeps the address stable. **Webhooks are silently discarded while stopped** — expected, not a fault.

## Patching the OS

Patch **in place**. Do not rebuild the host to get a newer image — its plugins, credentials,
webhook secret, job configuration and build history exist only on its volume, and a replacement
instance does not attach it.

```bash
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
aws ec2 wait instance-status-ok --instance-ids "$(terraform output -raw instance_id)"

# Optional but cheap insurance before an upgrade:
aws ec2 create-snapshot --volume-id <root volume> --description "jenkins pre-upgrade $(date +%F)"

ssh -i ~/.ssh/voteball-jenkins ec2-user@<elastic ip>
sudo dnf update --releasever=latest -y
sudo systemctl reboot            # required when the kernel is in the update set
```

After the reboot, `systemctl is-active jenkins` and `curl -sI http://localhost:8080/login` are the
check. Jenkins itself comes from the jenkins.io repo and is **not** moved by `dnf update
--releasever=latest`; upgrading Jenkins is a separate decision with its own plugin-compatibility
risk.

**Why the instance never plans a replacement:** `lifecycle.ignore_changes` covers `ami` for exactly
this reason — see the comment in `main.tf`. An instance's AMI id is fixed at launch, so patching in
place does not change it, and without that entry every new Amazon Linux release would make
`terraform apply` destroy this host. Verified 2026-07-21: after upgrading
`2023.12.20260710 → 2023.12.20260720` and rebooting onto kernel `6.1.176`, `terraform plan` still
reports *No changes*.

## If Jenkins is not running after apply

`user_data` runs once and Terraform does not verify it. Check:

```bash
sudo tail -50 /var/log/cloud-init-output.log
sudo systemctl status jenkins docker
sudo bash /var/lib/cloud/instance/user-data.txt    # the script is idempotent; safe to re-run
```
