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
# Refresh the final-snapshot name in state first -- see Gotchas below for why
# a bare `terraform destroy -var=...` isn't enough on its own.
terraform apply -auto-approve -target=module.database.aws_db_instance.main \
  -var-file=voteball.tfvars -var="db_final_snapshot_suffix=$(date +%Y%m%d%H%M%S)"
terraform destroy -var-file=voteball.tfvars
cd ..
```

Deletes everything: EC2, RDS, EIP, Route 53 record, IAM, SNS. RDS takes a
**final snapshot before deleting** (the `apply -target` step above gives it
a unique name so repeated destroys don't collide — don't skip it). Don't
lose `terraform.tfstate` or `voteball.tfvars` (gitignored, local-only) or
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
to remove one (both need a Bearer token from `POST /api/admin/login`). To
force a genuinely empty
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
- **The frontend has the mirror-image problem**: Ansible ships the *whole*
  `files/nginx/` directory to the node, but `files/nginx/Dockerfile` itself
  `COPY`s files by explicit name into the image. A new frontend file (new
  `.js`/`.css`/`.html`) that isn't added to that `COPY` line gets shipped to
  the node and then silently dropped at image-build time — no error, just a
  404 for that file once deployed. Shipped once for real (`i18n.js`, fixed
  in `d02e255`) before being caught by testing the live site after deploy.
- **`terraform destroy -var="db_final_snapshot_suffix=..."` alone does not give you a fresh
  snapshot name.** `final_snapshot_identifier` is a plain resource argument, and `destroy`
  deletes using the value already recorded in **state from the last `apply`** — it does not
  recompute the argument from a `-var` passed to `destroy` itself. Routine `apply` runs never
  pass that var (only the old `destroy` docs did), so the suffix baked into state is almost
  always still the `"manual"` default. If a snapshot named `voteball-db-final-manual` already
  exists from an earlier destroy, every later destroy then fails with
  `DBSnapshotAlreadyExists: Cannot create the snapshot ... already exists`, no matter what
  `-var` you pass on that destroy call. Fix: `terraform apply -target=module.database.aws_db_instance.main`
  with a fresh `-var` first (verified as a true no-op otherwise: `0 to add, 1 to change, 0 to
  destroy`, only `final_snapshot_identifier` moves) to write the new name into state, *then*
  destroy. Hit for real on 2026-07-15; the **Destroy** section above now does this by default.
- **The next deploy must skip the current RDS snapshot — it predates the club-name
  uniqueness migration and still has the duplicate rows that migration fixes.** This
  branch's `clubs.domestic_league_id` work adds `CREATE UNIQUE INDEX ... clubs_name_en_uidx`
  to `schema.sql`, which `db.py`'s `init_db` runs unconditionally on backend startup. The
  most recent snapshot was taken before this branch existed, so it still has real duplicate
  club rows (e.g. two "Arsenal" rows, one per league) — `seed.sql`'s `ON CONFLICT DO NOTHING`
  only guards fresh inserts, it does nothing about rows already committed in a restored
  snapshot. Restoring it will make `CREATE UNIQUE INDEX` hit a `UniqueViolation` during
  schema init (before `app.run`), crash-looping the backend pod. Since no votes exist yet,
  the fix is to not restore that snapshot: delete `terraform/snapshot.auto.tfvars` before
  the next `terraform apply` (see "Redeploying after a destroy" above — same mechanism used
  there to force a fresh empty database) so the database initializes from this branch's
  already-deduplicated `seed.sql` instead. This is a one-time step for the deploy that first
  picks up this migration, not a standing requirement.
- **The snapshot/restore mechanism (added 2026-07-12) hasn't been exercised
  through a real destroy→apply cycle yet** — `terraform validate` passes and
  the "no snapshot exists" path is confirmed against real AWS, but the
  actual restore-from-snapshot path will get its first real test on your
  next destroy/redeploy. If it doesn't work as expected, `snapshot_identifier`
  is in `lifecycle.ignore_changes` on the RDS resource (`terraform/modules/database/main.tf`)
  specifically so a bad restore doesn't force-replace the DB on a later
  unrelated `apply` — worth knowing if you need to debug it.
- **A changing home IP mid-deploy silently kills SSH, and looks nothing like an auth
  problem.** `ssh_allowed_cidr` in `voteball.tfvars` locks the EC2 security group's port 22
  rule to whatever IP you had at `apply` time. If your ISP/router reassigns your public IP
  partway through a long `ansible-playbook site-k3s.yml` run (this one takes 15-20+ minutes —
  Docker+k3s install, three image builds, then Helm), every subsequent SSH attempt — Ansible's
  and a manual `ssh` alike — hits `ssh: connect to host ... port 22: Connection timed out`.
  That's a **security-group silent drop**, not a refused connection or a credentials issue, so
  it's easy to misdiagnose as host-side trouble (CPU throttling, a hung sudo prompt, etc.) —
  AWS's own instance/system status checks stay green throughout, since they don't depend on
  your source IP at all. Symptom check: if `curl -s https://checkip.amazonaws.com` now returns
  a different address than what's in `ssh_allowed_cidr`, that's the cause. Fix: update
  `ssh_allowed_cidr` to the current IP and re-`apply` (or add a temporary wider rule), then
  re-run `ansible-playbook site-k3s.yml` — it's idempotent, safe to resume from wherever it
  stopped. Hit for real on 2026-07-16.
