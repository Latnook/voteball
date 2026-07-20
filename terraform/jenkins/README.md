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
terraform init
terraform apply -var-file=jenkins.tfvars
```

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

## If Jenkins is not running after apply

`user_data` runs once and Terraform does not verify it. Check:

```bash
sudo tail -50 /var/log/cloud-init-output.log
sudo systemctl status jenkins docker
sudo bash /var/lib/cloud/instance/user-data.txt    # the script is idempotent; safe to re-run
```
