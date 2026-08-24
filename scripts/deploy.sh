#!/usr/bin/env bash
# Full ordered deploy. Stops before `terraform apply` so you confirm the (billed) change yourself.
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

# Optional repo-root credentials file (gitignored), the env-var equivalent of terraform/voteball.tfvars:
# ADMIN_USERNAME / ADMIN_PASSWORD / JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD / GITHUB_TOKEN, so an
# unattended run needs only `VOTEBALL_AUTO_APPROVE=1 ./scripts/deploy.sh`.
#
# Two things here are load-bearing, and getting either wrong reproduces the exact symptom this exists
# to prevent -- being prompted anyway, which is indistinguishable from the file not existing at all:
#
#   1. `set -a`. The file holds bare `KEY=value` lines with no `export`, and the seed scripts in
#      steps 3/3b/3c are child processes that inherit only EXPORTED variables. Sourcing without it
#      sets shell variables the preflight below can read but the seed scripts cannot -- half-working.
#   2. Re-asserting the pre-existing environment AFTER the source. A sourced assignment is
#      unconditional, so the file would otherwise silently beat an explicit
#      `ADMIN_PASSWORD=... ./scripts/deploy.sh` -- the override you would reach for precisely when
#      rotating the value the file still holds. Everything else in this script treats the environment
#      as the winner (see the `${VAR:-}` guards below and DB_PASS/tfvars); this keeps that consistent.
#      GITHUB_TOKEN joins this list for the same reason: unlike the other four, it is genuinely
#      OPTIONAL (see step 3c) -- but an operator rotating it with
#      `GITHUB_TOKEN=newvalue ./scripts/deploy.sh` still has to win over a stale one sitting in
#      deploy.env, exactly like ADMIN_PASSWORD does.
if [ -f deploy.env ]; then
  declare -A _preset=()
  for _v in ADMIN_USERNAME ADMIN_PASSWORD JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD DB_PASS GITHUB_TOKEN; do
    [ -n "${!_v:-}" ] && _preset["$_v"]="${!_v}"
  done
  set -a; . ./deploy.env; set +a
  for _v in "${!_preset[@]}"; do
    printf -v "$_v" '%s' "${_preset[$_v]}"
    export "${_v?}"
  done
  unset _preset _v
  echo "Loaded credentials from ./deploy.env." >&2
fi

. scripts/lib/config.sh
require_config
TFVARS="voteball.tfvars"

# Terraform prompts for confirmation by default -- that is the intended behaviour for a human at a
# terminal. Set VOTEBALL_AUTO_APPROVE=1 only for unattended/automated runs.
APPROVE=()
[ "${VOTEBALL_AUTO_APPROVE:-0}" = "1" ] && APPROVE=(-auto-approve)

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if [ ! -f "terraform/$TFVARS" ]; then
  echo "ERROR: terraform/$TFVARS is missing (see docs/deploy.md, One-time setup)." >&2
  exit 1
fi

# Steps 3 and 3b (seed-eks-secret.sh, seed-jenkins-secret.sh) need four credentials between them.
# They are only USED at those steps, but we collect them HERE -- before the ~15-minute billed
# `terraform apply` in step 6 (and the smaller targeted apply in step 2) -- so a missing value fails
# cheaply instead of after the bill has already started (hit for real on the 2026-07-21 rebuild, for
# DB_PASS/ADMIN_PASSWORD; the same reasoning applies to the Jenkins pair added 2026-07-30). Prompting
# up front also means an interactive deploy needs no env vars at all: you are asked once, then the
# rest of the run is unattended. Anything already in the environment is left untouched, so the
# detached/CI path (pass them all in) still works. We `export` what we read so the seed scripts
# inherit it and never re-prompt.
#
# Test the terminal by actually opening /dev/tty, not with `[ -r /dev/tty ]` -- the latter consults
# permissions and returns TRUE in exactly the detached case we need to catch (verified 2026-07-21),
# so it would make this guard silently useless.
has_tty() { (exec </dev/tty) 2>/dev/null; }

# Prompt for a secret on /dev/tty and export it, unless it is already set in the environment.
prompt_secret() {   # prompt_secret VARNAME "prompt text"
  local var="$1" text="$2" val="${!1:-}"
  if [ -z "$val" ]; then
    read -rsp "$text: " val </dev/tty && echo >&2
  fi
  if [ -z "$val" ]; then
    echo "ERROR: $var must not be empty." >&2
    exit 1
  fi
  printf -v "$var" '%s' "$val"
  export "${var?}"
}

# db_password already lives in voteball.tfvars, and steps 2 and 5 apply that same -var-file, so read
# it from there instead of asking -- the seeded DB_PASS then matches RDS by construction, with no way to
# fat-finger a mismatch. Only ADMIN_PASSWORD (which is not in tfvars) is actually prompted below.
if [ -z "${DB_PASS:-}" ] && DB_PASS="$(tf_db_password "terraform/$TFVARS")" && [ -n "$DB_PASS" ]; then
  export DB_PASS
  echo "Using db_password from terraform/${TFVARS} (not prompting for it)." >&2
fi

# Prompt for a non-secret value on /dev/tty and export it, unless it is already set in the
# environment. Same shape as prompt_secret, but visible (read, not read -s) -- for values like a
# username that are fine to echo and are easier to double-check if you can see them typed.
prompt_plain() {   # prompt_plain VARNAME "prompt text"
  local var="$1" text="$2" val="${!1:-}"
  if [ -z "$val" ]; then
    read -rp "$text: " val </dev/tty
  fi
  if [ -z "$val" ]; then
    echo "ERROR: $var must not be empty." >&2
    exit 1
  fi
  printf -v "$var" '%s' "$val"
  export "${var?}"
}

if has_tty; then
  prompt_secret DB_PASS        "Database password (db_password from terraform/voteball.tfvars)"
  prompt_secret ADMIN_PASSWORD "Admin password for '${ADMIN_USERNAME:-admin}'"
  # Step 6b seeds the Jenkins secret the same way -- collected here, not inline, for the identical
  # reason: seed-jenkins-secret.sh would otherwise prompt for these itself, after the billed apply.
  prompt_plain  JENKINS_ADMIN_USER     "Jenkins admin username"
  prompt_secret JENKINS_ADMIN_PASSWORD "Jenkins admin password"
elif [ -z "${DB_PASS:-}" ] || [ -z "${ADMIN_PASSWORD:-}" ] || \
     [ -z "${JENKINS_ADMIN_USER:-}" ] || [ -z "${JENKINS_ADMIN_PASSWORD:-}" ]; then
  cat >&2 <<'MSG'
ERROR: no terminal is attached, and DB_PASS / ADMIN_PASSWORD / JENKINS_ADMIN_USER /
JENKINS_ADMIN_PASSWORD are not all set.

Steps 3 and 3b seed Secrets Manager with those four values. Without a terminal this run cannot ask
for them, and it would otherwise fail only after Terraform had already built (and started billing
for) the infrastructure. Stopping now instead.

Either run this from a real terminal (you will be prompted up front), or supply the answers:

  DB_PASS='...' ADMIN_USERNAME=admin ADMIN_PASSWORD='...' \
  JENKINS_ADMIN_USER='...' JENKINS_ADMIN_PASSWORD='...' \
  VOTEBALL_AUTO_APPROVE=1 ./scripts/deploy.sh

(VOTEBALL_AUTO_APPROVE=1 only skips Terraform's "type yes" prompt -- on its own it does NOT make
this script unattended.)
MSG
  exit 1
fi

# EKS API allow-list preflight. cluster_endpoint_public_access_cidrs has no default (2026-08-23
# review, T3-2), so an unset value fails `terraform plan` -- but it fails at step 6, after steps 2-5
# have already created ECR repositories, seeded three secrets and pushed images. Worse is a value
# that is SET but stale: the apply succeeds, and then step 7's kubectl and everything after it hang
# and time out against a control plane that is quietly dropping this machine's packets. That reads
# like a broken cluster, not like an access-list miss, and it happens after ~13 billed minutes.
#
# Checked here, before anything is created, and it is a WARNING rather than a hard stop: a CI runner
# or a deliberately open ["0.0.0.0/0"] are both legitimate and neither should block a deploy.
if ! ./scripts/refresh-api-cidr.sh --check >/dev/null 2>&1; then
  echo >&2
  echo "WARNING: terraform/${TFVARS} does not name this machine's current public address in" >&2
  echo "         cluster_endpoint_public_access_cidrs. If the list does not cover wherever this" >&2
  echo "         deploy runs from, every kubectl call after step 7 will TIME OUT rather than be" >&2
  echo "         refused -- which looks like a dead cluster. Current state:" >&2
  ./scripts/refresh-api-cidr.sh --check 2>&1 | sed 's/^/         /' >&2 || true
  echo "         Fix with: ./scripts/refresh-api-cidr.sh   (then re-run this script)" >&2
  echo "         Ignore it if the list is deliberately broad, or if you deploy from elsewhere." >&2
  echo >&2
fi

step "1/11  Resolving the newest DB snapshot"
./scripts/find-latest-snapshot.sh

step "2/11  Creating ECR repositories and secret containers (targeted apply)"
# helm_release.jenkins in step 6's full apply pulls ${CLUSTER}-jenkins:<tag> immediately -- Helm
# waits for that pull to succeed before the release is considered done. After a fresh
# destroy/rebuild the ECR repos are gone (ecr.tf sets force_delete = true), so without this the
# image does not exist yet and the full apply fails several minutes in, mid-bill. A targeted apply
# of just the repositories first means step 5 has somewhere to push the Jenkins image into before
# step 6 needs it there.
#
# data.aws_caller_identity.current is targeted too, and it is NOT optional. `-target` prunes the
# graph to the targeted subgraph and writes ONLY the root outputs inside it. `ecr_registry` is built
# from that data source rather than from any ECR resource (outputs.tf), so without this target it is
# silently absent from state -- while `ecr_repository_urls` survives, making the step look like it
# worked. Steps 4 and 5 both resolve the registry with `tf_out ecr_registry`, so the run then dies
# on the NEXT step with "Terraform output 'ecr_registry' is unavailable" (hit on the 2026-07-31
# rebuild, the first destroy/deploy cycle after this targeted apply was introduced).
#
# The three Secrets Manager containers (and their placeholder versions) are targeted for the same
# kind of reason: steps 3, 3b and 3c write the REAL credentials into them, and the Jenkins one has to
# be in place before the full apply creates helm_release.jenkins (see the comment on step 3b). The
# grafana container has no such hard deadline -- nothing in the full apply reads it, only the
# ArgoCD-synced ExternalSecrets do, much later -- but it is targeted here anyway so step 3c can seed
# it in the same place as the other two, before the billed apply, rather than needing its own
# special-cased later targeted apply.
./scripts/bootstrap-tf-backend.sh
terraform -chdir=terraform init -upgrade -backend-config=backend.hcl
terraform -chdir=terraform apply -var-file="$TFVARS" \
  -target=aws_ecr_repository.app -target=aws_ecr_repository.cache \
  -target=aws_secretsmanager_secret_version.app_placeholder \
  -target=aws_secretsmanager_secret_version.jenkins_placeholder \
  -target=aws_secretsmanager_secret_version.grafana_placeholder \
  -target=data.aws_caller_identity.current "${APPROVE[@]}"

step "3/11  Seeding app credentials into Secrets Manager"
./scripts/seed-eks-secret.sh

step "3b/11 Seeding Jenkins credentials into Secrets Manager"
# Idempotent: a no-op, printing nothing sensitive, whenever the secret already holds a real deploy
# key -- i.e. on every run of deploy.sh except the one right after a fresh destroy/rebuild.
#
# BOTH seeding steps run BEFORE the full apply, and that ordering is load-bearing. The full apply
# creates helm_release.jenkins and its ExternalSecret together, and External Secrets Operator copies
# voteball/jenkins into the `jenkins-secret` Kubernetes Secret ONCE at creation, then only every
# refreshInterval (1h). Seeding afterwards means that first sync copies Terraform's EMPTY placeholder:
# the controller boots with JENKINS_ADMIN_USER, JENKINS_ADMIN_HASH and GITHUB_WEBHOOK_SECRET all
# unset, JCasC builds the admin account from nothing, and every login 401s until the hourly refresh
# happens to land. The rebuild reports complete success throughout -- Jenkins is simply locked out.
# Observed on the 2026-07-31 rebuild, the first destroy/deploy cycle after Jenkins moved in-cluster.
# docs/cicd.md step 1 has always said to seed "before first apply"; this makes the script agree.
./scripts/seed-jenkins-secret.sh

step "3c/11 Seeding Grafana data source credentials into Secrets Manager"
# Idempotent, same shape as 3/3b: a no-op once voteball/grafana already holds a real db_password
# (scripts/seed-grafana-secret.sh's own guard). Without this step, charts/voteball's
# externalSecret.grafanaEnabled and charts/observability's externalSecret.enabled/dbEnabled/
# githubEnabled are all committed TRUE, so ArgoCD would sync ExternalSecrets asking ESO for a
# db_password that Terraform's placeholder does not carry -- ESO reports SecretSyncedError, the
# resource goes Degraded, ArgoCD's WHOLE sync reports phase Failed, and because anything failing
# after application-cd's Promote stage triggers a rollback, every CD run becomes
# deploy-fails-then-roll-production-back. That exact outage happened on 2026-08-24: four consecutive
# failed CD runs, from a monitoring feature that had not been seeded yet reverting unrelated
# application fixes. Seeding here, before step 6's full apply creates ArgoCD, closes the gap the same
# way steps 3/3b already close it for the app and Jenkins secrets.
#
# GITHUB_TOKEN is genuinely OPTIONAL -- unlike DB_PASS/ADMIN_PASSWORD/JENKINS_ADMIN_* above, this
# script does not stop to prompt for it and does not fail without it (see
# scripts/seed-grafana-secret.sh). If it is set (deploy.env or the environment) it is used; if a
# terminal is attached the script still offers an optional prompt; otherwise it is skipped and only
# db_password is seeded -- the GitHub data source's three panels stay blank until it is added later,
# and nothing else is affected (docs/design/2026-08-24-grafana-datasources-design.md decision 5: no
# alert, SLI or incident path depends on it).
./scripts/seed-grafana-secret.sh

step "3d/11 Registering the CI deploy key and webhook on GitHub"
# Registration is deliberately here, immediately after the key is minted, and NOT at the end of the
# deploy where it used to live. Step 9 below pushes values.yaml to master, and the webhook that
# survived the previous cluster fires on that push -- so Jenkins fetches with the new deploy key
# while GitHub is still holding the previous rebuild's. The result is a red
# "Permission denied (publickey)" build in the middle of a deploy that is otherwise going fine.
# Observed on the 2026-08-03 rebuild: build 1 failed at 19:13:18Z, and the key was registered at
# 19:13:39Z -- 21 seconds too late. Registering before anything can push closes the window.
#
# SKIP_PROBE=1 because the probe pings the webhook and expects Jenkins to answer, which cannot be
# true yet -- the cluster is not built until step 6. The probe still runs, at step 11b, once it can
# actually mean something.
#
# Same NOT-FATAL treatment as step 11b, for the same reason in reverse: this runs before the billed
# apply, so failing here would abort a deploy over a GitHub API call that step 11b can still fix.
if ! SKIP_PROBE=1 ./scripts/register-github-ci.sh; then
  echo
  echo "WARNING: could not register the deploy key/webhook on GitHub before the apply." >&2
  echo "         The deploy continues, but a push during it may produce one failed build." >&2
  echo "         Step 11b will retry; or run ./scripts/register-github-ci.sh yourself." >&2
fi

step "4/11  Mirroring the Trivy vulnerability database into ECR"
# Must exist before any image is scanned. Not otherwise on any automated path (see
# scripts/mirror-trivy-db.sh) -- skipping this after a fresh rebuild means every
# `trivy --db-repository` lookup in the pipeline errors on the very first build.
./scripts/mirror-trivy-db.sh

step "5/11  Building and pushing the Jenkins controller image"
# Pushed under the TAG ALREADY PINNED in terraform/voteball.tfvars (jenkins_image_tag), not a fresh
# git SHA -- ci/jenkins/ changes rarely, and this only needs to reproduce the image the full apply
# below is about to ask ECR for. Bumping jenkins_image_tag to a new build is a separate, deliberate,
# by-hand step (see the variable's description in terraform/variables.tf), not something a routine
# deploy should do on its own.
JENKINS_TAG="$(tfvar jenkins_image_tag "" "terraform/$TFVARS")"
if [ -z "$JENKINS_TAG" ]; then
  echo "ERROR: jenkins_image_tag is not set in terraform/${TFVARS}." >&2
  exit 1
fi
./scripts/build-push-ecr.sh jenkins "$JENKINS_TAG"

step "6/11  Building AWS infrastructure (Terraform will ask you to confirm)"
echo "This creates real, billed resources (~\$200/month while up)."

# --- BEGIN aws progress watcher ---
# Terraform prints `Still creating... [6m20s elapsed]` against opaque resource addresses for ~13
# minutes and never says what AWS is doing underneath. This narrates it: the EKS control plane and
# RDS state, the ASG launching Spot instances, their EC2 status checks going initializing -> ok
# (the OS answering), the RDS event stream, then the nodes joining and the ten Helm add-ons landing.
#
# It is a SEPARATE process writing to the same terminal -- deliberately not a pipe. Piping the apply
# through anything would put tee/PIPESTATUS between us and Terraform's exit code, which is the
# failure mode called out in destroy.sh ("a masked exit code can report a failed run as success").
# The line below is therefore byte-for-byte the same apply it always was.
WATCH_PID=""
if [ "${VOTEBALL_NO_WATCH:-0}" != "1" ]; then
  ./scripts/watch-aws-progress.sh apply &
  WATCH_PID=$!
  trap 'kill "$WATCH_PID" 2>/dev/null || true' EXIT
fi
# --- END aws progress watcher ---

terraform -chdir=terraform apply -var-file="$TFVARS" "${APPROVE[@]}"

if [ -n "$WATCH_PID" ]; then
  kill "$WATCH_PID" 2>/dev/null || true
  trap - EXIT
fi

step "7/11  Pointing kubectl at the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

step "7b/11 Minting the ArgoCD CD token"
# Nothing else ever generates ARGOCD_AUTH_TOKEN. seed-jenkins-secret.sh (step 3b) only ever copies
# it from the environment -- empty on a fresh install, since ArgoCD does not exist yet at step 3b --
# and it exits early once a deploy key is present, so a re-seed can never fill it in either. Left
# alone, application-cd's Deploy stage fails at every future build with an ArgoCD auth error, while
# this whole script reports success. This step is that fix.
#
# Has to run HERE, not earlier: the jenkins-cd account is created by step 6's full apply
# (terraform/addon-argocd.tf's accounts.jenkins-cd), and reaching argocd-server needs the kubectl
# context step 7 just set up. It has to run before anyone would expect CD to work -- i.e. before any
# push can trigger application-cd -- so it lands here rather than at the end of the script.
#
# Idempotent: a no-op on every run except right after a fresh destroy/rebuild, when the secret's
# token is empty or has gone stale.
#
# NOT FATAL, same treatment as steps 3d and 11b and for the same reason: everything up to here has
# already succeeded, and failing the whole deploy over an ArgoCD API call would misreport a working
# cluster as broken. It warns loudly instead, with the one command that fixes it standalone.
if ! ./scripts/seed-argocd-token.sh; then
  echo
  echo "WARNING: could not mint/verify the ArgoCD token for the jenkins-cd account." >&2
  echo "         The deploy continues, but application-cd's Deploy stage will fail auth until this" >&2
  echo "         is fixed. Run standalone once the cluster is up:  ./scripts/seed-argocd-token.sh" >&2
fi

step "8/11  Building and pushing container images"
./scripts/build-push-ecr.sh

step "9/11  Syncing values.yaml and promoting to the release branch"
./scripts/sync-values-from-tf.sh

# ArgoCD deploys whatever is on master, NOT what is on this disk. Bootstrapping it (step 11) while
# values.yaml is still uncommitted makes ArgoCD immediately revert the cluster to the OLD image tag
# -- which, after a rebuild, points at an image that does not exist in the fresh ECR, so every pod
# lands in ImagePullBackOff. Observed on the 2026-07-20 rebuild. Commit before ArgoCD exists.
# Resolve the image digests and write them into values.yaml BEFORE committing, so that master and
# the release branch carry IDENTICAL image references.
#
# THIS IS NOT COSMETIC -- leaving master on tags while release carries digests breaks the bootstrap.
# Step 10 Helm-installs from the working tree (master) on a fresh cluster, and step 11 then hands the
# release to ArgoCD, which syncs the RELEASE branch. Helm 4 applies server-side, so Helm would own
# .spec...containers[].image at "repo:tag" while ArgoCD tries to apply "repo@sha256:..." -- a
# different value for a field another manager owns, which server-side apply refuses. Two managers may
# co-own a field only while they apply the SAME value; that rule is spelled out at step 10 and this is
# the same failure in the opposite direction. Introduced and caught on 2026-08-23, during the deploy
# that first exercised digest pinning.
#
# Non-fatal on failure: the chart falls back to the tag when a digest is empty, which is a working
# deploy -- and in that case master and release BOTH fall back, so they still agree.
step_tag_pre="$(sed -nE 's/^  tag: "([^"]*)".*/\1/p' charts/voteball/values.yaml | head -1)"
if [ -n "$step_tag_pre" ]; then
  if pre_digests="$(TAG="$step_tag_pre" AWS_REGION="$(tfvar aws_region il-central-1)" \
                    ECR_PREFIX="$(tfvar cluster_name voteball)" \
                    ./scripts/ci/resolve-digests.sh 2>/dev/null)"; then
    printf '%s\n' "$pre_digests" | while IFS="$(printf '\t')" read -r dname ddigest; do
      [ -n "$dname" ] || continue
      python3 - "$dname" "$ddigest" <<'PY'
import sys, re
name, digest = sys.argv[1], sys.argv[2]
p = "charts/voteball/values.yaml"
lines = open(p).read().splitlines(keepends=True)
out, indig = [], False
for line in lines:
    if re.match(r'^  digests:\s*$', line):
        indig = True; out.append(line); continue
    if indig and re.match(rf'^    {re.escape(name)}:', line):
        out.append(f'    {name}: "{digest}"\n'); continue
    if indig and not line.startswith("    ") and line.strip():
        indig = False
    out.append(line)
open(p, "w").write("".join(out))
PY
    done
    echo "Digest-pinned all four images in values.yaml (master and release will match)."
  else
    echo "WARNING: could not resolve image digests -- values.yaml stays tag-based." >&2
    echo "         master and release still agree, so the deploy is correct; the next" >&2
    echo "         application-cd run will add the digests." >&2
  fi
fi

if ! git diff --quiet -- charts/voteball/values.yaml; then
  echo "values.yaml changed — committing so ArgoCD deploys these values, not the stale ones."
  git add charts/voteball/values.yaml
  # Deliberately NO [skip ci] here, though it looks like it belongs. This commit touches only
  # charts/voteball/values.yaml, and the Jenkinsfile gates every build stage on
  # `changeset 'services/**'` (G3), so it rebuilds nothing -- the marker would buy nothing.
  # (After a controller restart G3b makes this push run the pipeline rather than skip it, because
  # there is no changelog to judge by. That is still not a rebuild: step 8 has already pushed the
  # images for this SHA, so G1 short-circuits build/scan/push, and the tag bump finds values.yaml
  # already naming this tag and commits nothing. The build is a clean no-op, not a loop.)
  # A marker here would also actively break things: the Guard stage reads HEAD's message alone and
  # aborts the WHOLE build, while `changeset` spans every commit since the last build. If an app-code
  # commit and this one land in the same build window, the marker would abort the build that was
  # supposed to build the app-code commit, and nothing would retry it.
  git commit -m "Deploy: sync values.yaml from Terraform outputs"

  # Wait for Jenkins to be able to RECEIVE the webhook before pushing, because GitHub does not retry
  # a failed push delivery -- it fires once and the build is gone.
  #
  # This push fires the webhook. Jenkins is created during step 6's apply, but "the helm release
  # exists" is not "the ALB has a healthy target": on the 2026-08-04 06:30 rebuild the push landed at
  # 06:45:42 and GitHub got 502 "failed to connect to host" in 0.05s, while the very same endpoint
  # answered 200 thirty-five seconds later. No build ran, nothing in the deploy output said so, and
  # the delivery had to be replayed by hand. The 2026-08-04 00:22 rebuild survived only because
  # Jenkins happened to win that race.
  #
  # Same shape as the deploy-key race that moved registration to step 3d: deploy.sh pushing to master
  # before the thing that must react to the push is ready. Fixing that one did not fix this one --
  # there, GitHub did not know the key; here, the ALB has no healthy target yet.
  #
  # The wait itself lives in scripts/wait-for-webhook.sh, extracted for the same reason
  # scripts/ci/should-skip-build.sh is: a decision that can only be exercised by running a real
  # deploy is exactly the kind that goes untested until it fails in production. Its own offline test
  # is scripts/tests/test-webhook-wait.sh.
  #
  # Deliberately NOT fatal. Everything above this line succeeded, and the push must still happen --
  # skipping it would leave master naming a stale image tag for ArgoCD to sync. On timeout it pushes
  # anyway and prints the one command that recovers a lost delivery.
  R="${GITHUB_REPO:-$(tfvar github_repo)}"
  if ! ./scripts/wait-for-webhook.sh; then
    echo "WARNING: Jenkins never answered, so this push may produce no build at all." >&2
    echo "         GitHub delivers a push event once and never retries it. If no build appears," >&2
    echo "         replay the delivery rather than re-pushing (a re-push changes the SHA):" >&2
    echo "           H=\$(gh api repos/${R}/hooks --jq '.[0].id')" >&2
    echo "           D=\$(gh api repos/${R}/hooks/\$H/deliveries --jq '[.[]|select(.event==\"push\")][0].id')" >&2
    echo "           gh api -X POST repos/${R}/hooks/\$H/deliveries/\$D/attempts" >&2
  fi

  # Rebase onto origin FIRST. CI pushes its own "ci: image tag <sha> [skip ci]" commit to master
  # after every app-code build, so the local branch is routinely behind and a plain push is rejected
  # non-fast-forward -- which then skipped the ArgoCD bootstrap below. This bites on essentially
  # every deploy that follows a code push (hit on the 2026-07-20 rebuild). Rebase, never force.
  # --autostash because the rebase aborts on ANY unrelated unstaged change, and a working tree
  # mid-session usually has some. Without it this "fix" would fail for a different reason.
  if ! git pull --rebase --autostash; then
    echo "ERROR: could not rebase onto origin/master (conflict?)." >&2
    echo "Resolve it, push, then run: ./scripts/render-argocd-app.sh | kubectl apply -f -" >&2
    SKIP_ARGOCD=1
  elif ! git push; then
    echo "ERROR: could not push values.yaml." >&2
    echo "Refusing to bootstrap ArgoCD -- it would sync a stale image tag over this deploy." >&2
    echo "Push manually, then re-run: ./scripts/render-argocd-app.sh | kubectl apply -f -" >&2
    SKIP_ARGOCD=1
  fi
fi

# --- the release branch ---------------------------------------------------------------------------
# ArgoCD watches `release`, not `master` (since 2026-08-23 -- see
# docs/design/2026-08-23-release-branch-and-digest-design.md and the comment in
# argocd/voteball-application.yaml.tmpl). So the branch has to EXIST, and has to name this cluster's
# images, before step 11 creates the Application -- otherwise ArgoCD is pointed at a branch that is
# either missing or naming the previous cluster's ECR registry, and every pod lands in
# ImagePullBackOff. That is the same failure the values.yaml commit above exists to prevent, one
# branch over: observed on the 2026-07-20 rebuild, and the reason this is step 9 and not step 12.
#
# Runs OUTSIDE the `if values.yaml changed` block on purpose. On a re-run where the file is already
# correct there is nothing to commit to master, but `release` may still not exist (first deploy) or
# may still point at the previous cluster's tag -- and "nothing changed on master" says nothing about
# either.
#
# Digests are resolved here rather than left empty so the cluster is digest-pinned from its FIRST
# deploy instead of from its first pipeline run. If the lookup fails the promotion still goes ahead
# with tags only: the chart falls back to the tag when a digest is empty, which is a working deploy,
# whereas refusing to promote would leave ArgoCD with no branch at all.
if [ "${SKIP_ARGOCD:-0}" != "1" ]; then
  step_tag="$(sed -nE 's/^  tag: "([^"]*)".*/\1/p' charts/voteball/values.yaml | head -1)"
  if [ -z "$step_tag" ]; then
    echo "ERROR: could not read the image tag out of charts/voteball/values.yaml." >&2
    echo "Refusing to promote to the release branch without knowing what is being deployed." >&2
    SKIP_ARGOCD=1
  else
    echo "Promoting $(git rev-parse --short HEAD) to the release branch (tag $step_tag)..."
    step_digests=""
    if step_digests_raw="$(TAG="$step_tag" AWS_REGION="$(tfvar aws_region il-central-1)" \
                           ECR_PREFIX="$(tfvar cluster_name voteball)" \
                           ./scripts/ci/resolve-digests.sh 2>/dev/null)"; then
      step_digests="$(printf '%s' "$step_digests_raw" | awk '{printf "%s=%s ", $1, $2}')"
      echo "  digest-pinning all four images."
    else
      echo "  WARNING: could not resolve image digests from ECR -- promoting by tag only." >&2
      echo "           The chart falls back to the tag, so this deploys correctly; the next" >&2
      echo "           application-cd run will add the digests." >&2
    fi

    if ! SOURCE_SHA="$(git rev-parse HEAD)" TAG="$step_tag" DIGESTS="$step_digests" \
         ./scripts/ci/promote-to-release.sh; then
      echo "ERROR: could not promote to the release branch." >&2
      echo "Refusing to bootstrap ArgoCD -- it would watch a branch that does not name this" >&2
      echo "cluster's images. Fix the push, then run:" >&2
      echo "  SOURCE_SHA=\$(git rev-parse HEAD) TAG=$step_tag ./scripts/ci/promote-to-release.sh" >&2
      echo "  ./scripts/render-argocd-app.sh | kubectl apply -f -" >&2
      SKIP_ARGOCD=1
    fi
    # promote-to-release.sh leaves the checkout ON the release branch. Everything after this point
    # (and anyone reading the repo afterwards) expects master, and leaving a deploy script having
    # silently switched branches is its own small trap.
    git checkout -q master 2>/dev/null || true
  fi
fi

step "10/11 Installing the app"
# WHO APPLIES depends on whether ArgoCD is already managing this release, and running the wrong one
# does not degrade gracefully -- it fails the deploy outright.
#
#   FRESH CLUSTER -- step 11 has not created the Application yet, so nothing else applies this chart.
#   Helm is the only way to get pods up, and it collides with nothing.
#
#   EXISTING CLUSTER -- ArgoCD already owns every field of this release, and step 9 has just pushed a
#   new image tag. `helm upgrade` would apply that tag while ArgoCD still holds `.image` at the
#   previous one, and Helm 4's server-side apply refuses: two managers may co-own a field only while
#   they apply the SAME value. Steps 9->10 exist precisely to CHANGE the tag, so this is guaranteed
#   on every re-run, not occasional (observed 2026-08-10 on all three Deployments and the backup
#   CronJob). `--force-conflicts` would "fix" it by taking ownership away from ArgoCD -- the one
#   thing this repo's delivery model forbids. So we let ArgoCD do its job and verify that it did.
#   Full reasoning, and why the check is revision-specific, is in scripts/wait-for-argocd-sync.sh.
#
# The rollout checks below run on BOTH paths: whoever applied, the same three Deployments must land.
if kubectl get application voteball -n argocd >/dev/null 2>&1; then
  if [ "${SKIP_ARGOCD:-0}" = "1" ]; then
    # values.yaml never reached master (step 9 said so), but ArgoCD is live and deploys master. It
    # would ship the OLD values, and Helm cannot apply the new ones without fighting it for
    # ownership. Neither applier can produce a correct result, so stop here rather than wait out a
    # 300-second timeout for a commit that was never pushed.
    echo "ERROR: ArgoCD manages this release, but values.yaml is not on master (see step 9)." >&2
    echo "       Push it, then re-run:  ./scripts/wait-for-argocd-sync.sh" >&2
    exit 1
  fi
  echo "ArgoCD already manages this release — it applies, not Helm (see the comment above)."
  ./scripts/wait-for-argocd-sync.sh
else
  echo "No ArgoCD Application yet — installing with Helm (fresh cluster; step 11 hands over)."
  helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
fi
kubectl rollout status deployment/backend  -n devops-app --timeout=300s
kubectl rollout status deployment/frontend -n devops-app --timeout=300s
kubectl rollout status deployment/worker   -n devops-app --timeout=300s

step "11/11 Bootstrapping ArgoCD (GitOps takes over from here)"
if [ "${SKIP_ARGOCD:-0}" = "1" ]; then
  echo "SKIPPED — values.yaml is not on master (see the error above)."
else
  # Rendered from the `github_repo` Terraform output rather than applied from a static file -- see
  # scripts/render-argocd-app.sh. `set -o pipefail` is on, so a failed render aborts here instead of
  # feeding kubectl an empty stdin (which exits 0 and would report a bootstrap that never happened).
  ./scripts/render-argocd-app.sh | kubectl apply -f -
fi

step "11b/11 Checking GitHub can actually reach this cluster's Jenkins"
# The REGISTRATION half of this now happens at step 3d, before anything can push. What is left here
# is the probe, which is the half that needs a cluster: it pings the webhook and classifies the
# result, proving jenkins.<domain> resolves, the ALB routes, and Jenkins is answering. None of that
# can be true at step 3d, which is why the two are split -- see the comment there.
#
# PROBE_ONLY=1 also side-steps a subtlety: register-github-ci.sh exits early and silently when the
# key and hook already match, which after step 3d they always do. Calling it plainly here would
# print "nothing to do" and never probe at all, quietly dropping the post-deploy reachability check.
#
# DELIBERATELY NOT FATAL. Everything above this line has already worked: the site is up and serving.
# Failing the whole deploy over a GitHub API call would misreport a working deployment as a broken one.
# It warns loudly instead, and the fix is one standalone command.
if ! PROBE_ONLY=1 ./scripts/register-github-ci.sh; then
  echo
  echo "WARNING: could not confirm GitHub can reach Jenkins." >&2
  echo "         The DEPLOY ITSELF SUCCEEDED — the site is up. Only CI may be affected: if pushes" >&2
  echo "         trigger no build, re-run:  ./scripts/register-github-ci.sh" >&2
fi

step "11c/11 Verifying the cluster can resolve its own public hostname"
# The canary hits https://<app_domain> every 30s and IS the denominator for every ratio SLI on this
# site -- with no organic traffic, an availability ratio with no requests in it falls back to
# `or vector(1)` and reports a confident, wrong 100%. So the canary being unable to resolve the
# hostname is not a cosmetic problem; it makes the headline SLI lie.
#
# It happens on rebuilds. App pods start at step 10 and resolve <app_domain> before external-dns has
# created the A record, and because that name already exists in Route53 for other reasons, the answer
# is NOERROR-with-no-A rather than NXDOMAIN -- a NEGATIVE answer cached against the zone's SOA
# minimum TTL, 86400 seconds. Observed on 2026-08-24: still unresolved 15 minutes later while the VPC
# resolver returned both ALB addresses.
#
# The script restarts CoreDNS ONLY when the outside world can resolve a name the cluster cannot,
# which is that cache's signature. NOT FATAL, for the same reason as 11b: the site is already up and
# serving real users; this affects what the dashboards can see, not what visitors get.
if ! ./scripts/verify-public-dns.sh; then
  echo
  echo "WARNING: the cluster cannot resolve ${APP_DOMAIN}." >&2
  echo "         The DEPLOY ITSELF SUCCEEDED — the site is up for the internet. But the in-cluster" >&2
  echo "         canary cannot reach it, so voteball:availability:ratio5m will report 1 while" >&2
  echo "         measuring nothing, and VoteballJourneyTrafficStopped will fire in ~10 minutes." >&2
  echo "         Re-run:  ./scripts/verify-public-dns.sh" >&2
fi

step "11d/11 Restarting Grafana to pick up its data source credentials, if needed"
# envFromSecret(s) project a Secret's keys as environment variables AT POD START ONLY. kube-
# prometheus-stack's Grafana lands during step 6's apply, long before ArgoCD (step 11) syncs
# charts/observability and ESO fills grafana-datasources/grafana-datasources-github -- so on a fresh
# deploy the running Grafana pod predates its own credentials, and Grafana expands an unset
# provisioning variable to an EMPTY STRING rather than erroring: it authenticates to RDS as
# grafana_ro with a blank password and the PostgreSQL panel fails SASL auth, with nothing in
# Grafana's own health checks noticing. See docs/design/2026-08-24-grafana-datasources-design.md,
# "Verification outcome", finding 3.
#
# CONDITIONAL, same shape as 11c's CoreDNS restart: the script itself checks whether the Secret
# exists and whether the running pod already has it projected, and only restarts when both "there is
# something to project" and "it has not been projected yet" are true -- an unconditional restart on
# every deploy would be pointless churn on a Spot cluster and, worse, the kind of step nobody could
# safely remove later because nobody could tell whether it was still doing anything.
#
# NOT FATAL, for the same reason as 11b/11c: the application is already up and serving; this affects
# only what two Grafana dashboards can show, not what visitors get.
if ! ./scripts/restart-grafana-datasources.sh; then
  echo
  echo "WARNING: Grafana may still be authenticating to PostgreSQL with a stale/empty password." >&2
  echo "         The DEPLOY ITSELF SUCCEEDED — the site is up. Re-run:" >&2
  echo "           ./scripts/restart-grafana-datasources.sh" >&2
fi

cat <<EOF

Deploy complete.

  Verify:
      kubectl get pods -n devops-app
      curl -sf https://${APP_DOMAIN}/api/options | head -c 120

  DNS can take a minute to propagate after a rebuild.
EOF
