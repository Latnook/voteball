# CI/CD pipeline

How a code change becomes a running pod, with no manual deploy step.

CI is **Jenkins**, running on a dedicated EC2 host built by `terraform/jenkins/`. It replaced a GitHub
Actions pipeline on 2026-07-20; the reasoning for every choice below is in
[`docs/design/2026-07-20-jenkins-migration-design.md`](design/2026-07-20-jenkins-migration-design.md),
whose gotcha labels **G1–G7** are referenced throughout.

Everything below was verified end-to-end on 2026-07-20 against the live cluster.

---

## The short version

```
git push (services/**)  →  webhook  →  Jenkins  →  ECR  →  values.yaml bump  →  ArgoCD  →  pods roll
        you                            ~2 min                  commit                       rolling update
```

Nobody runs `kubectl` or `helm`. **Jenkins does not deploy** — it stops at "push images, commit the new
tag". ArgoCD notices the commit and rolls the Deployments. That split is deliberate: it means Jenkins
holds **no cluster credentials at all**, so a compromised build host cannot touch the cluster.

---

## The pipeline, step by step

The pipeline lives in [`Jenkinsfile`](../Jenkinsfile) at the repository root, and the Jenkins job is
configured as *Pipeline script from SCM* — so the build definition is in the repository and reviewable,
not hidden in Jenkins' database.

### 1. Trigger — GitHub webhook

A push to `master` sends a webhook to `http://<elastic-ip>:8080/github-webhook/`. Jenkins verifies the
HMAC signature GitHub attaches using a shared secret, so a random host inside GitHub's IP ranges cannot
start builds.

Only app-source changes rebuild images: the build/scan/push stages carry
`when { anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } } }` (**G3**). Editing
`README.md`, `terraform/` or `docs/` triggers the job but builds nothing.

> **Non-obvious:** the filter is a path match, not a "was this app code?" judgement. A docs-only commit
> that also touches `services/backend/schema.sql` (e.g. fixing a comment) *will* trigger a full build.
> That is correct — the file is baked into the backend image — but it surprises people.

`FORCE_BUILD` is a checkbox on "Build with Parameters". It exists because a **manually** triggered build
has an empty changeset and would otherwise skip every stage, making "Build Now" a silent no-op.

### 2. Guard — is this our own commit? (G2)

**This stage is load-bearing and must never be removed.** The last stage of the pipeline commits the
bumped image tag back to `master`. `[skip ci]` is a *GitHub Actions* convention; **Jenkins has never
heard of it**. Without the guard, the webhook fires on Jenkins' own commit, Jenkins builds it, bumps the
tag, commits again — an unbounded build loop that burns money and continuously rolls production pods.

So the first stage reads the head commit message and, if `scripts/ci/should-skip-build.sh` says `skip`,
sets `currentBuild.result = 'NOT_BUILT'` and aborts. It runs unconditionally and first, so a `[skip ci]`
commit cannot be built even manually with `FORCE_BUILD` ticked.

It is a visible stage rather than a plugin setting precisely so that removing it is an obvious edit in a
reviewed file, not an invisible configuration change.

### 3. Authenticate to AWS — instance profile, no stored keys

An IAM role (`voteball-jenkins`) is attached to the EC2 instance itself. Any `aws` CLI call on that host
picks up temporary credentials from the instance metadata service automatically. There is **no OIDC
provider, no `configure-aws-credentials` step, and no key material stored anywhere** — not in Jenkins,
not in git, not on disk. ECR login is just:

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

The role can push to `repository/voteball-*` and call `ecr:GetAuthorizationToken`, and **nothing else** —
no EKS, RDS, S3, SNS or Secrets Manager. Verified on the live host: `aws ecr get-login-password` works,
`aws eks list-clusters` returns `AccessDeniedException`.

IMDSv2 is required (`http_tokens = "required"`), so a server-side request forgery on the host cannot
trivially read the role's credentials.

The account ID and registry hostname are **derived at runtime** (`aws sts get-caller-identity`), never
hardcoded — the repo's forkability rule applies to the `Jenkinsfile` too.

### 4. Already built? (G1)

ECR repositories are created with `image_tag_mutability = "IMMUTABLE"`, and images are tagged with the
short git SHA. Re-running a build for the same commit would therefore try to push a tag that already
exists, and ECR rejects it — a red build caused by nothing being wrong. Under GitHub Actions that was
rare; in Jenkins, "Build Now" and replaying a build to debug a later stage are routine.

`scripts/ci/images-exist.sh` asks ECR whether all four images for this SHA already exist. If they do,
build/scan/push are skipped and the pipeline goes straight to the tag bump, saying why. The skip only
happens on a **positive** answer — a lookup failure builds normally, so the worst case is a redundant
build, never a green build that silently ships nothing.

### 5. Build, scan, push

Four images (`backend`, `worker`, `nginx`, `backup`) are built and tagged with the short git SHA — never
`latest`, so every deployed pod maps to an exact commit.

**Trivy blocks the pipeline** on fixable `CRITICAL`/`HIGH` findings in the three app images. The `backup`
image is third-party (`postgres:17-alpine` + aws-cli) and is scanned **report-only**, since its CVEs are
upstream Go-tooling issues outside this project's control.

Trivy runs as a **container**, pinned to `aquasec/trivy:0.58.1` in the `Jenkinsfile` rather than installed
on the host — so the version a reader of the pipeline sees is the version that actually ran, and a new
upstream release cannot turn the pipeline red without a deliberate edit.

`/var/lib/trivy-cache` is mounted into every scan. Without it the ~100 MB vulnerability database is
re-downloaded on each of four scans, every build, which risks anonymous-pull rate limits on ghcr.io
failing builds for reasons unrelated to the code. The first build downloaded 100.80 MiB; every later scan
reused the cache.

ECR also has `scan_on_push = true`, so images are scanned again independently after the push — defence in
depth that survives whatever happens to CI.

### 6. Bump the tag and commit back (G4)

```bash
sed -i -E "s/^  tag: \".*\"/  tag: \"$TAG\"/" charts/voteball/values.yaml
git commit -m "ci: image tag $TAG [skip ci]"
git pull --rebase --autostash origin master
git push origin HEAD:master
```

Jenkins has no ambient git identity (GitHub Actions supplied a free `GITHUB_TOKEN`; Jenkins does not), so
this uses a **GitHub deploy key with write access**, stored in Jenkins' credentials store and injected by
`sshagent`. A deploy key is preferred over a personal access token because it is scoped to exactly one
repository — if the build host were compromised, the blast radius is this repo, not the whole account.

The `git pull --rebase --autostash` is the same fix commits `ed39db2`/`1269ba8` applied to
`scripts/deploy.sh` for the identical race: `origin/master` may have moved while the build ran. On a
conflict the pipeline aborts the rebase explicitly rather than leaving the workspace mid-rebase, which
would wedge the next build's checkout.

`[skip ci]` is still written into the message — for continuity, readability, and so the repository stays
portable — but in Jenkins it is the **Guard stage**, not the marker, that does the work.

### 7. ArgoCD syncs

The `voteball` Application watches `charts/voteball` on `master` with `automated: {prune, selfHeal}`. It
picks up the new tag unprompted and Kubernetes performs a rolling update across all three Deployments.

### 8. Cleanup (G5)

GitHub's runners were destroyed after every job; this host is not. `post { always { docker image prune -f } }`
plus `buildDiscarder` (last 20 builds) keeps the 30 GB volume from filling with four image builds per run.

---

## First-time setup runbook

Done once, through the Jenkins UI. (Converting this to **JCasC** — Jenkins Configuration as Code — is
deliberately deferred; see "Deferred" below.)

**1. Build the host.**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/voteball-jenkins -C voteball-jenkins   # once
cd terraform/jenkins
cp jenkins.tfvars.example jenkins.tfvars      # set admin_cidr to your IP as a /32
../../scripts/bootstrap-tf-backend.sh         # once per account: state bucket + backend.hcl
terraform init -backend-config=backend.hcl
terraform apply -var-file=jenkins.tfvars
```

`terraform/jenkins/` is a **separate stack with its own state**, applied and destroyed independently of
`terraform/`. That is the whole point: `scripts/destroy.sh` tears the application stack down on every
rebuild cycle, and a CI server owned by that stack would lose its build history and configuration each
time.

**2. Open the UI.** It is not publicly reachable — only GitHub's webhook ranges can reach port 8080, and
port 22 is open only to your own IP. Reach it through an SSH tunnel:

```bash
cd terraform/jenkins && terraform output -raw ssh_tunnel_command
# ssh -i ~/.ssh/voteball-jenkins -L 8080:localhost:8080 ec2-user@<elastic-ip>
# then browse http://localhost:8080
```

Tunnelled traffic arrives at Jenkins from `localhost`, so it is never evaluated against the security
group. That is why the UI works for you while `curl http://<elastic-ip>:8080` from the same machine
times out — which was verified, and is the intended posture.

**3. Unlock and create the admin user.** The initial password is
`sudo cat /var/lib/jenkins/secrets/initialAdminPassword`.

**4. Install exactly these plugins:** Git, Pipeline, GitHub, Credentials Binding, SSH Agent.

Deliberately **not** Docker Pipeline: that plugin exists for the `docker.build()` DSL, and the
`Jenkinsfile` shells out to the `docker` CLI instead. Installing it would add a component to patch that
nothing uses.

**5. Set the global environment variables.** *Manage Jenkins → System → Global properties → Environment
variables*:

| Name | Value |
|---|---|
| `AWS_REGION` | e.g. `il-central-1` |
| `CLUSTER_NAME` | `voteball` |

These are the direct equivalent of the old GitHub repo variables, and they exist for the same reason:
**identity stays out of the repository**, so a fork supplies its own. The pipeline fails fast with a
clear message if either is unset, rather than building image references like
`null.dkr.ecr.null.amazonaws.com`.

**6. Leave the Jenkins URL as `http://localhost:8080/`.** That is correct — the only human ever reaches
it through the tunnel. The consequence is that the GitHub plugin must **not** auto-manage hooks
(*Manage Jenkins → System → GitHub → Advanced → uncheck "Manage hooks"*), because it would otherwise
register a `localhost` URL that GitHub cannot reach.

**7. Add two credentials** (*Manage Jenkins → Credentials → System → Global*):

| ID | Kind | What |
|---|---|---|
| `voteball-deploy-key` | SSH username with private key, username `git` | a **repository-scoped GitHub deploy key with write access** (GitHub → repo Settings → Deploy keys) |
| `github-webhook-secret` | Secret text | a random shared secret, e.g. `openssl rand -hex 32` |

> **Install the SSH key from a file, not by pasting it into the textarea.** Pasting drops the trailing
> newline, and OpenSSH then cannot load the key at all — see failure modes below; this cost real time.

**8. Seed known_hosts.** SSH checkout fails outright if github.com's host keys are unknown:

```bash
sudo -u jenkins ssh-keyscan github.com >> /var/lib/jenkins/.ssh/known_hosts
```

**9. Create the job.** New Item → name `voteball` → **Pipeline**.

- Definition: **Pipeline script from SCM**, SCM: Git
- **Repository URL: `git@github.com:<owner>/<repo>.git` — SSH, MANDATORY.** `sshagent` only affects SSH
  remotes; with an HTTPS URL the deploy key is silently ignored and the final push fails.
- Credentials: `voteball-deploy-key`
- Branch: `*/master`, Script Path: `Jenkinsfile`
- Build trigger: **GitHub hook trigger for GITScm polling**

Not Freestyle (that would put the build definition in Jenkins' database instead of the repository,
defeating the point) and not Multibranch (this project commits directly to `master`).

**10. Run the job once with no parameters (G6).** Jenkins registers a pipeline's `parameters` block only
after it has read the `Jenkinsfile` during a build, so `FORCE_BUILD` does not exist yet. **That first run
doing nothing is expected, not a fault.** Afterwards the checkbox appears.

**11. Configure the webhook secret on the Jenkins side.** *Manage Jenkins → System → GitHub → Shared
secrets*, using the `github-webhook-secret` credential. Then verify it actually persisted — see failure
mode 3, which is the single most time-consuming problem in this migration.

**12. Add the GitHub webhook.** Repo → Settings → Webhooks → Add:

- Payload URL `http://<elastic-ip>:8080/github-webhook/` — **the trailing slash is required**
- Content type `application/json`, Secret = the same shared secret, event: just the push event

**If you are migrating from another CI system rather than starting fresh, disarm it before enabling this
webhook.** Two armed pipelines both build the same commit and then race to push `values.yaml` to
`master` — which is exactly the collision this migration was ordered to avoid.

---

## Running the instance

```bash
cd terraform/jenkins
aws ec2 stop-instances  --instance-ids "$(terraform output -raw instance_id)"
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
```

Cost is about **$37/month** running (t3.medium in `il-central-1`) and about **$6/month** stopped — EBS
~$2.40 plus the Elastic IP ~$3.60, because AWS bills a public IPv4 address whether or not the instance is
running. All Jenkins state lives on the EBS volume and the Elastic IP keeps the address stable, so
stop/start is safe and the webhook URL never changes.

**Webhooks are silently discarded while the instance is stopped.** That is expected, not a fault: GitHub
records a failed delivery and nothing else happens. Start the instance and run a manual build with
`FORCE_BUILD`, or push again.

Two consequences of protecting Jenkins' state are worth knowing before you tear the stack down: the root
volume is `delete_on_termination = false` and the instance carries
`lifecycle { ignore_changes = [user_data] }`. Both exist because Jenkins' credentials and job
configuration live **only** on that volume. The cost is that destroying the stack leaves an **orphaned
30 GB volume you must delete by hand**.

---

## Failure modes

The first three actually happened during this migration and are recorded with their real root causes;
the rest are the G1–G7 differences the design predicted.

| Symptom | Cause | Fix |
|---|---|---|
| Build reaches the final stage, then the push fails or hangs on a credential prompt | The job's SCM URL is **HTTPS**. `sshagent` only affects SSH remotes, so the deploy key was never offered | Set the SCM URL to `git@github.com:<owner>/<repo>.git` |
| `error in libcrypto` then `Permission denied (publickey)` | The private key pasted into the Jenkins credentials textarea **lost its trailing newline**, so OpenSSH could not *load* it and offered no key at all. The `Permission denied` line is misleading — GitHub was refusing an anonymous connection | Install the credential programmatically from a file rather than pasting |
| Webhook "ping" returns 200 but every push returns **400 "No valid signature found"** | `GitHubPluginConfig` (github plugin 1.47.0) has both a legacy singular `hookSecretConfig` and a plural `hookSecretConfigs` list. `getHookSecretConfigs()` prefers the list when present and only falls back to the singular otherwise — so an **empty-but-present** `<hookSecretConfigs/>` beat the fallback, leaving zero secrets configured, and this version requires at least one, rejecting signed and unsigned requests identically | Write the **singular** form in `/var/lib/jenkins/org.jenkinsci.plugins.github.config.GitHubPluginConfig.xml`: `<hookSecretConfig><credentialsId>github-webhook-secret</credentialsId></hookSecretConfig>`, then restart. `setHookSecretConfigs()` via Groovy reports success but does **not** persist |
| **G2** — Jenkins rebuilds its own tag-bump commit, forever | The Guard stage or `scripts/ci/should-skip-build.sh` was removed. `[skip ci]` does nothing in Jenkins on its own | Restore the Guard stage. See the standing warning in `CLAUDE.md` |
| **G1** — re-running a build fails with `tag already exists` | ECR tags are `IMMUTABLE` and images are tagged by commit SHA | Already handled by the "Already built?" stage; if it fails, check the instance role still has `ecr:DescribeImages` |
| A commit you expected to build finishes `NOT_BUILT` immediately, and the site does not change | The commit **message** contains the skip marker anywhere in it — including when merely *writing about* it, which is what a maintainer documenting this pipeline does. The Guard deliberately fails safe toward skipping: a wrong skip costs one manual rebuild, a wrong build costs an unbounded loop | Expected behaviour, not a fault. Re-run with **Build with Parameters → `FORCE_BUILD`**… except that a marker-bearing commit can *never* be built, even with `FORCE_BUILD`, because the Guard runs first and unconditionally. Amend the commit message (write "skip-ci" or "the skip marker" in prose instead) and push again |
| **G3** — "Build Now" does nothing | A manual build has an empty changeset, so the `services/**` condition is false | Use *Build with Parameters* and tick `FORCE_BUILD` |
| **G4** — `git push` denied at the last stage | Deploy key missing, read-only, or (see row 1) an HTTPS remote | Deploy key with **write** access + SSH SCM URL |
| **G5** — builds fail on a full disk | Persistent host, four images per build | `docker image prune -f` runs in `post { always }`; check it, and `buildDiscarder` keeps 20 builds |
| **G6** — `FORCE_BUILD` checkbox is missing | The job has never run, so Jenkins has not read the `parameters` block yet | Run the job once; it registers them |
| **G7** — a build failed and nobody noticed | Jenkins sends no email without SMTP, and this Jenkins has no public UI | Accepted, see below. Check the Jenkins UI, or `kubectl get application voteball -n argocd` to see whether the deployed tag actually advanced |
| Images pushed but the tag-bump push failed | Interrupted build. A re-run hits G1 and skips straight to the bump — but only if the commit still touches `services/**` | Re-run with `FORCE_BUILD` ticked |
| `RepositoryNotFoundException` pushing to ECR | **The main stack is destroyed.** ECR repos have `force_delete = true` and go with it | Expected while torn down. Deploy first |
| CI is green but the site doesn't change | No cluster, or no ArgoCD Application | `kubectl get application voteball -n argocd`; `./scripts/deploy.sh` bootstraps it |
| Pods go to `ImagePullBackOff` after a sync | `values.yaml` on `master` names a tag/registry that doesn't exist in this account's ECR | `./scripts/sync-values-from-tf.sh --check` |
| Jenkins is not running after `terraform apply` | `user_data` runs once and Terraform does not verify it succeeded | `sudo tail -50 /var/log/cloud-init-output.log`; the script is idempotent, so `sudo bash /var/lib/cloud/instance/user-data.txt` is safe to re-run |
| Docker Hub pulls fail with `TOOMANYREQUESTS` | Anonymous pull limits are shared across the host's single Elastic IP | Wait, or authenticate the daemon to Docker Hub |

**Diagnostic worth keeping:** when the webhook returned 400, signed and unsigned requests failed
**identically**. That proved it was not a secret-value mismatch — a wrong value would reject the signed
request differently from an unsigned one. Testing locally on the box with a computed HMAC (signed → 200,
unsigned → 400) is far faster than guessing at the GitHub end.

---

## Doing it by hand

`./scripts/deploy.sh` runs the same work locally (build → push → sync values → helm → bootstrap ArgoCD).
Useful for the first deploy of a fresh cluster, when there is no ArgoCD yet for CI's commit to reach.

Note the ordering constraint it encodes: **`values.yaml` must be committed and pushed before the ArgoCD
Application is created.** Bootstrapping ArgoCD against a `master` that still holds stale values makes it
immediately revert the deploy — after a rebuild, to an image tag that no longer exists, so every pod
lands in `ImagePullBackOff`.

---

## Verified run (2026-07-20)

The live host: EC2 `i-08344c3d285db66df`, t3.medium, Amazon Linux 2023, 30 GB gp3 encrypted, Elastic IP
`51.85.19.95`, in the region's **default VPC** — deliberately not the application VPC, so the two
lifecycles never touch.

| Build | Trigger | Result |
|---|---|---|
| 2 | manual, no parameters | Registered the `FORCE_BUILD` parameter (**G6**). Did nothing else — expected, not a fault |
| 3 | manual, `FORCE_BUILD` | ✅ 2 minutes. Four images built + pushed as `0aa4d5d` |
| 4 | **webhook**, `09827ca` | ✅ Full build, images pushed, tag bumped → commit `3c4cd93 ci: image tag 09827ca [skip ci]` |
| 5 | **webhook**, `3c4cd93` — Jenkins' own commit | ✅ Guard fired. `Finished: NOT_BUILT`. **This is the G2 proof, and it happened with no human involved** |
| 6 | manual, same commit | ✅ Guard fired again — confirmed twice |

**Exactly one bump commit exists. There was no loop.**

Trivy on build 3:

| Image | Result |
|---|---|
| `backend`, `worker`, `nginx` | **0 HIGH, 0 CRITICAL** — blocking gate passed |
| `backup` | 14 HIGH + 1 CRITICAL, **all** in `usr/local/bin/gosu` (a Go binary inside `postgres:17-alpine`) — report-only, did not block |

The notable one is **CVE-2025-68121** (CRITICAL, certificate validation in Go's `crypto/tls`). It is
upstream, in a third-party base image, reachable only from a daily CronJob running inside the VPC — which
is why the backup image is scanned report-only rather than blocking. It is surfaced, not hidden.

Delivery:

| Stage | Result |
|---|---|
| ArgoCD synced `3c4cd93` unprompted | ✅ |
| All three Deployments rolled to `09827ca` | ✅ zero downtime, no `ImagePullBackOff` |
| Site returned 200; `/api/options` returned 200 | ✅ |

Two behaviours the design assumed and the run confirmed empirically:
`currentBuild.result = 'NOT_BUILT'` **survives** the `error()` that follows it (Jenkins only ever worsens
a build result, never improves it), and `post { failure }` correctly did **not** fire on a skipped build.

**Repo noise, acknowledged not hidden:** four empty commits sit on `master` from debugging the webhook —
`9bed4f1`, `1b16a45`, `a76fbb3`, `09827ca`. History was not rewritten, because this repo never
force-pushes.

---

## Deferred, on purpose

- **JCasC (Jenkins Configuration as Code).** Jenkins is configured through its UI once and recorded as
  the runbook above. A later pass converts that into `jenkins.yaml` + `plugins.txt` so the host
  self-configures on boot. Banking a green build first was deliberate — the config file is much easier to
  write having done the steps by hand.
- **SSM Session Manager** as the UI access path, which would let port 22 close entirely.
- **Build-failure notifications (G7).** Jenkins sends nothing without SMTP, and provisioning mail
  credentials on the build host is a surface this project declined to add. The compensating practice:
  verification means checking the Jenkins UI or ArgoCD's Application state, **not** inferring success from
  the site still working. Recorded as a decision, not an oversight — revisit if the project outlives the
  course.
