#!/usr/bin/env bash
# Full ordered deploy. Stops before `terraform apply` so you confirm the (billed) change yourself.
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

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

# Steps 6 and 6b (seed-eks-secret.sh, seed-jenkins-secret.sh) need four credentials between them.
# They are only USED at those steps, but we collect them HERE -- before the ~15-minute billed
# `terraform apply` in step 5 (and the smaller targeted apply in step 2) -- so a missing value fails
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

Steps 6 and 6b seed Secrets Manager with those four values. Without a terminal this run cannot ask
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

step "1/11  Resolving the newest DB snapshot"
./scripts/find-latest-snapshot.sh

step "2/11  Creating ECR repositories (targeted apply)"
# helm_release.jenkins in step 5's full apply pulls ${CLUSTER}-jenkins:<tag> immediately -- Helm
# waits for that pull to succeed before the release is considered done. After a fresh
# destroy/rebuild the ECR repos are gone (ecr.tf sets force_delete = true), so without this the
# image does not exist yet and the full apply fails several minutes in, mid-bill. A targeted apply
# of just the repositories first means step 4 has somewhere to push the Jenkins image into before
# step 5 needs it there.
#
# data.aws_caller_identity.current is targeted too, and it is NOT optional. `-target` prunes the
# graph to the targeted subgraph and writes ONLY the root outputs inside it. `ecr_registry` is built
# from that data source rather than from any ECR resource (outputs.tf), so without this target it is
# silently absent from state -- while `ecr_repository_urls` survives, making the step look like it
# worked. Steps 3 and 4 both resolve the registry with `tf_out ecr_registry`, so the run then dies
# on the NEXT step with "Terraform output 'ecr_registry' is unavailable" (hit on the 2026-07-31
# rebuild, the first destroy/deploy cycle after this targeted apply was introduced).
./scripts/bootstrap-tf-backend.sh
terraform -chdir=terraform init -upgrade -backend-config=backend.hcl
terraform -chdir=terraform apply -var-file="$TFVARS" \
  -target=aws_ecr_repository.app -target=aws_ecr_repository.cache \
  -target=data.aws_caller_identity.current "${APPROVE[@]}"

step "3/11  Mirroring the Trivy vulnerability database into ECR"
# Must exist before any image is scanned. Not otherwise on any automated path (see
# scripts/mirror-trivy-db.sh) -- skipping this after a fresh rebuild means every
# `trivy --db-repository` lookup in the pipeline errors on the very first build.
./scripts/mirror-trivy-db.sh

step "4/11  Building and pushing the Jenkins controller image"
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

step "5/11  Building AWS infrastructure (Terraform will ask you to confirm)"
echo "This creates real, billed resources (~\$200/month while up)."
terraform -chdir=terraform apply -var-file="$TFVARS" "${APPROVE[@]}"

step "6/11  Seeding app credentials into Secrets Manager"
./scripts/seed-eks-secret.sh

step "6b/11 Seeding Jenkins credentials into Secrets Manager"
# Idempotent: a no-op, printing nothing sensitive, whenever the secret already holds a real deploy
# key -- i.e. on every run of deploy.sh except the one right after a fresh destroy/rebuild. Only
# that run needs FORCE_ROTATE-free reseeding; see scripts/seed-jenkins-secret.sh.
./scripts/seed-jenkins-secret.sh

step "7/11  Pointing kubectl at the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

step "8/11  Building and pushing container images"
./scripts/build-push-ecr.sh

step "9/11  Syncing values.yaml from Terraform outputs"
./scripts/sync-values-from-tf.sh

# ArgoCD deploys whatever is on master, NOT what is on this disk. Bootstrapping it (step 11) while
# values.yaml is still uncommitted makes ArgoCD immediately revert the cluster to the OLD image tag
# -- which, after a rebuild, points at an image that does not exist in the fresh ECR, so every pod
# lands in ImagePullBackOff. Observed on the 2026-07-20 rebuild. Commit before ArgoCD exists.
if ! git diff --quiet -- charts/voteball/values.yaml; then
  echo "values.yaml changed — committing so ArgoCD deploys these values, not the stale ones."
  git add charts/voteball/values.yaml
  # Deliberately NO [skip ci] here, though it looks like it belongs. This commit touches only
  # charts/voteball/values.yaml, and the Jenkinsfile already gates every build stage on
  # `changeset 'services/**'` (G3), so it triggers no rebuild anyway -- the marker would buy
  # nothing. It would also actively break things: the Guard stage reads HEAD's message alone and
  # aborts the WHOLE build, while `changeset` spans every commit since the last build. If an app-code
  # commit and this one land in the same build window, the marker would abort the build that was
  # supposed to build the app-code commit, and nothing would retry it.
  git commit -m "Deploy: sync values.yaml from Terraform outputs"

  # Rebase onto origin FIRST. CI pushes its own "ci: image tag <sha> [skip ci]" commit to master
  # after every app-code build, so the local branch is routinely behind and a plain push is rejected
  # non-fast-forward -- which then skipped the ArgoCD bootstrap below. This bites on essentially
  # every deploy that follows a code push (hit on the 2026-07-20 rebuild). Rebase, never force.
  # --autostash because the rebase aborts on ANY unrelated unstaged change, and a working tree
  # mid-session usually has some. Without it this "fix" would fail for a different reason.
  if ! git pull --rebase --autostash; then
    echo "ERROR: could not rebase onto origin/master (conflict?)." >&2
    echo "Resolve it, push, then run: kubectl apply -f argocd/voteball-application.yaml" >&2
    SKIP_ARGOCD=1
  elif ! git push; then
    echo "ERROR: could not push values.yaml." >&2
    echo "Refusing to bootstrap ArgoCD -- it would sync master's stale image tag over this deploy." >&2
    echo "Push manually, then re-run: kubectl apply -f argocd/voteball-application.yaml" >&2
    SKIP_ARGOCD=1
  fi
fi

step "10/11 Installing the app"
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
kubectl rollout status deployment/backend  -n devops-app --timeout=300s
kubectl rollout status deployment/frontend -n devops-app --timeout=300s
kubectl rollout status deployment/worker   -n devops-app --timeout=300s

step "11/11 Bootstrapping ArgoCD (GitOps takes over from here)"
if [ "${SKIP_ARGOCD:-0}" = "1" ]; then
  echo "SKIPPED — values.yaml is not on master (see the error above)."
else
  kubectl apply -f argocd/voteball-application.yaml
fi

cat <<EOF

Deploy complete.

  Verify:
      kubectl get pods -n devops-app
      curl -sf https://${APP_DOMAIN}/api/options | head -c 120

  DNS can take a minute to propagate after a rebuild.
EOF
