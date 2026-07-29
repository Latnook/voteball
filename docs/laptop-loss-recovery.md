# If the laptop vanishes

What to do if the machine this project is run from is stolen, lost, or simply dies.

**This file is in git on purpose.** A recovery plan stored only on the thing that vanished is no plan
at all. Everything here can be done from a borrowed machine with nothing but a browser, an AWS login
and this repository.

Last verified against the live account on **2026-07-27**.

---

## First: which of the two emergencies is this?

They need opposite things from you, in opposite orders.

| | **It died** (SSD failure, dropped, water) | **Someone has it** (stolen, left behind) |
|---|---|---|
| The risk | Losing work | Losing *control* |
| First move | Rebuild, calmly | Rotate credentials, immediately |
| Time pressure | None — nothing is leaking | Minutes |

If you can't tell which — assume the second. Rotating credentials you didn't need to rotate costs you
an hour. Not rotating ones you did costs you the AWS account.

### Does full-disk encryption settle it?

**On this machine: no. Assume compromise.**

The disk is LUKS-encrypted and **unlocks itself from the TPM when powered on** — no passphrase is
typed at boot. That is convenient, and it is the detail that decides this whole document. It means:

- **Powered off is not "safe."** A thief presses the power button and the disk decrypts itself. The
  only thing left between them and your files is the **login/lock-screen password**.
- Worse, if the TPM enrollment is bound only to Secure Boot state (PCR 7), editing the kernel command
  line at the bootloader — `init=/bin/bash` — often does *not* change that measurement, which is a
  root shell on a decrypted disk without needing your password at all.

So for this laptop, **every theft is the "someone has it" case.** Go straight to
[the first hour](#if-someone-has-it-the-first-hour). Do not talk yourself into the calm path because
the disk is "encrypted."

**What the encryption still does buy you**, and it is not nothing: it defeats the *offline* attacks.
Pull the SSD out and read it in another machine, or boot from a USB stick, and the TPM measurements
change, so the key is never released. A casual thief who wipes and resells the machine gets nothing.
The exposure is specifically "someone deliberately powers this laptop on and attacks it."

Verified on 2026-07-27, for the record:

- Both `/` and `/home` are btrfs subvolumes on the LUKS volume — the AWS credentials, the build-host
  SSH key and the working copy are all inside it, not beside it.
- Swap is **zram** (RAM-backed), so no hibernation image carrying the volume key is ever written to
  disk. One thing that genuinely is closed.
- `/boot` is unencrypted, which is normal and holds nothing secret.

> **The fix, if you want "powered off = safe" back:** add a PIN to the TPM enrollment —
> `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes <root partition>` — then remove the
> PIN-less keyslot. Boot then asks for a short PIN, the key never unseals without it, and the offline
> protections stay. A strong LUKS passphrase in a keyslot you keep as a fallback is the safety net;
> do not remove your recovery key.

---

## If someone has it: the first hour

Do these in order. Each one is independent — if you get stuck on one, move to the next and come back.

### 1. Kill the AWS access key (this is the big one)

The laptop holds a long-lived access key in `~/.aws/credentials` for an IAM user with
**AdministratorAccess**. That is the keys to the whole account: every service, every secret, the
ability to delete everything and the backups with it.

From any browser, AWS Console → IAM → Users → your CLI user → *Security credentials* →
**Deactivate**, then **Delete** the access key.

```bash
# Or from a machine with another admin identity:
aws iam update-access-key --user-name <your cli user> --access-key-id <AKIA...> --status Inactive
aws iam delete-access-key --user-name <your cli user> --access-key-id <AKIA...>
```

Deactivate first and delete second: deactivation is instant and reversible, so do the thing that stops
the bleeding before the thing you might regret.

Then create a fresh key for your new machine — and this is the moment to **add MFA to that user**, so
a future stolen key alone isn't enough.

### 2. Cut off GitHub

Repo write access **is** production deploy access here: ArgoCD deploys whatever is on `master`, so
anyone who can push can change the live site without touching AWS at all.

- GitHub → Settings → *Developer settings* → **revoke** any personal access tokens.
- GitHub → Settings → *Applications* → revoke the GitHub CLI's authorisation.
- Repo → Settings → **Deploy keys** → the Jenkins key stays (it lives on the build host, not the
  laptop) — but check nothing unexpected is listed.
- **If you reach for branch protection on `master`, configure it carefully.** It is a genuine
  production control here, but this repo has no PR workflow and **Jenkins pushes straight to `master`**
  (`git push origin HEAD:master`, the tag bump). A naive "require pull requests" rule breaks the
  pipeline at its last stage *and* locks you out of your own direct pushes. If you want it, allow the
  deploy key as an exception — or skip it and rely on step 1 plus the deploy-key audit above.

### 3. Assume the SSH key to the build host is compromised

`~/.ssh/voteball-jenkins` is on the laptop. Whoever holds it, plus a permitted source IP, can get a
shell on the build server.

The cheap, immediate fix is to **remove the permitted IP**, which locks everybody out including the
thief — set `admin_cidr` in `terraform/jenkins/jenkins.tfvars` to a CIDR you control (or an unroutable
one), and `terraform apply`. The build host keeps running and keeps building; only human SSH is
closed. Replace the key properly later, see [The one key with no spare](#the-one-key-with-no-spare).

Or simply stop the instance — it costs nothing but a stopped CI server:

```bash
cd terraform/jenkins
aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"
```

### 4. Change the two application passwords

Both are stored only as one-way hashes, so the thief cannot read them off the disk — but if they were
in a browser password manager on that machine, treat them as known:

```bash
ADMIN_USERNAME='<yourname>' ADMIN_PASSWORD='<new>' ./scripts/seed-eks-secret.sh    # the site's admin page
JENKINS_ADMIN_USER='<yourname>' JENKINS_ADMIN_PASSWORD='<new>' ./scripts/seed-jenkins-secret.sh
```

The first also rotates the session key, signing out any admin session the thief might be holding —
which is the point. See [the deploy guide](deploy.md#change-the-admin-username-or-password) for how to
make the running app pick it up without waiting an hour.

### 5. What you do *not* need to panic about

- **The database password.** It is not exposed by the laptop alone — it lives in AWS Secrets Manager,
  and the copy in `terraform/voteball.tfvars` is on the encrypted disk. Rotate it in a calm week.
- **The site itself.** Nothing about a lost laptop changes what visitors see. There is no "the site is
  down" component to this emergency.

---

## What is actually lost

Verified on 2026-07-27 by inspecting the machine, not from memory.

| On the laptop | Really lost? | Why |
|---|---|---|
| `terraform/terraform.tfstate` + backups | **No** — they are empty shells | State moved to S3 on 2026-07-21. The local files contain **zero resources**. Deleting them changes nothing. |
| `terraform/jenkins/terraform.tfstate` | **No** — same, an empty leftover | Real state is `voteball/jenkins.tfstate` in the same bucket. |
| `terraform/backend.hcl` (both stacks) | No | Regenerated by `./scripts/bootstrap-tf-backend.sh`. |
| `terraform/voteball.tfvars` | **No, but reconstruct it carefully** | Four values: domain, Route53 zone, notification email — all knowable — and `db_password`, readable from Secrets Manager while the stack is up. See below. |
| `terraform/jenkins/jenkins.tfvars` | No | Region, cluster name, and your current IP. |
| `~/.ssh/voteball-jenkins` | **Yes — and there is no spare** | See [The one key with no spare](#the-one-key-with-no-spare). |
| `~/.aws/credentials` | No | Issue a new key; the old one should already be deleted. |
| `EXPLAINER.md`, `PROJECT-QA.md` | **Yes, permanently** | Gitignored personal notes. Nothing anywhere else holds them. |
| `.venv/` directories, `__pycache__`, kubeconfig | No | All rebuilt by a command. |
| Docker images built locally | No | Every image is in ECR, tagged by commit. |
| Anything committed and pushed | No | It's on GitHub. |

### Recovering `db_password` without the tfvars file

While the cluster is alive, the database password is in Secrets Manager, and Terraform needs it to
match. This prints it — so do it in a terminal you trust and clear the history afterwards:

```bash
aws secretsmanager get-secret-value --secret-id voteball/app-secret \
  --region <your region> --query SecretString --output text
```

If the stack is already destroyed, you don't need the old password at all: put a **new** one in
`voteball.tfvars`, and the snapshot restore sets the database's master password to it.

---

## Rebuilding on a new machine

Nothing here requires the old laptop. Roughly 30 minutes, most of it waiting.

```bash
# 1. Tools
#    terraform, aws, kubectl, helm, docker, python3, openssl

# 2. A fresh AWS key (created in the first hour, above)
aws configure
aws sts get-caller-identity          # confirm the right account

# 3. The repo
git clone https://github.com/<you>/voteball.git && cd voteball

# 4. The one settings file — four values, see docs/deploy.md
cp terraform/voteball.tfvars.example terraform/voteball.tfvars

# 5. Reconnect to the state that has been in S3 all along
./scripts/bootstrap-tf-backend.sh                    # finds/creates the bucket, writes backend.hcl
terraform -chdir=terraform init -backend-config=backend.hcl
terraform -chdir=terraform plan -var-file=voteball.tfvars
```

**Step 5 is the moment of truth.** If that `plan` says *No changes*, you have fully recovered: the new
machine now sees every resource the old one built. If it proposes to create things that already exist,
**stop** — you are pointed at the wrong bucket or the wrong account, and applying would build a
duplicate stack alongside the real one.

Then get back into everything else:

```bash
aws eks update-kubeconfig --region <your region> --name <your cluster_name>
kubectl get pods -n devops-app
```

The rest — dashboards, ArgoCD, Jenkins, the database — is
[Connect to each part](deploy.md#connect-to-each-part-dashboards-argocd-jenkins-the-database).

### If the cluster was destroyed too

`./scripts/deploy.sh` rebuilds it, restoring the newest database snapshot automatically. Votes
survive. The full sequence is in [the deploy guide](deploy.md#put-the-site-online).

---

## The one key with no spare

`~/.ssh/voteball-jenkins` is the **only** way to get a shell on the build host. There is no second
path, and this is worth understanding before you need it:

- The Jenkins instance profile grants ECR push and one secret read — **no SSM permissions**, so AWS
  Session Manager ("connect without SSH") will not work as things stand.
- The instance's web port is open only to GitHub's webhook ranges, never to you.

So if that key is gone, you cannot log in — even though the machine is running fine and still building.

**The non-destructive fix** — do this rather than rebuilding the host, which would destroy its build
history, job config and credentials:

1. Attach `AmazonSSMManagedInstanceCore` to the `<cluster_name>-jenkins` IAM role. The SSM agent is
   already installed **and running** on the host (verified 2026-07-27) — it is only the permission
   that is missing, so nothing has to be installed over a connection you don't have.
2. Reboot the instance from the AWS console, so the agent retries registration with its new
   permissions. Then connect with Session Manager.
3. From that shell, append a new public key to `/home/ec2-user/.ssh/authorized_keys`.

This is safe to apply: the instance has `ignore_changes` on its image and startup script precisely so
that routine Terraform runs never replace it.

**Better: prevent it.** Keep a copy of that private key in your password manager. It is 411 bytes.

---

## Do these now, so the above is boring

A short list, in descending order of what it would cost you not to have done.

1. **Add a PIN to the TPM unlock** (see above). Right now the disk decrypts itself on power-on, which
   is what turns any theft into a credential emergency. This is the one change that would let you
   treat a stolen-while-off laptop calmly.
2. **Put the Jenkins SSH private key in your password manager.** The single unrecoverable item.
3. **Add MFA to the admin IAM user**, and stop using a long-lived access key where you can. A key that
   has existed unrotated for months is exactly the one worth rotating on a schedule.
4. **Back up `terraform/voteball.tfvars`** to the password manager. Reconstructible, but knowing the
   database password without a live cluster is the difference between a calm rebuild and a tense one.
5. **Back up your personal notes** (`EXPLAINER.md`, `PROJECT-QA.md`) somewhere — they are the only
   truly single-copy documents in the project, and they are the ones you spent the most time on.
6. **Keep `admin_cidr` current.** When your ISP changes your IP, SSH to the build host starts timing
   out; fixing that under pressure, on a new machine, is a bad time to discover it.

*(Branch protection on `master` used to sit on this list. It is deliberately not here any more: with
no PR workflow and Jenkins pushing the tag bump directly to `master`, the naive form of it breaks CI.
See the note in the first hour above if you do want it.)*

---

## What survives no matter what happens to the laptop

Worth knowing on a bad day:

- **Terraform state** — S3, versioned, one object per stack.
- **The database** — RDS, plus a final snapshot on every teardown and 7-day point-in-time recovery.
- **Container images** — ECR, tagged by commit.
- **Every secret the app uses** — AWS Secrets Manager, synced into the cluster automatically. No human
  needs to have read them.
- **All code, charts and docs** — GitHub, and ArgoCD is still deploying from it. The site keeps
  running, keeps taking votes, and keeps alerting you, entirely without your laptop.

That last point is the real answer to the question. **The site does not need you to be present.**
