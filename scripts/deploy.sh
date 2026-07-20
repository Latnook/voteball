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

step "1/8  Resolving the newest DB snapshot"
./scripts/find-latest-snapshot.sh

step "2/8  Building AWS infrastructure (Terraform will ask you to confirm)"
echo "This creates real, billed resources (~\$200/month while up)."
terraform -chdir=terraform init -upgrade
terraform -chdir=terraform apply -var-file="$TFVARS" "${APPROVE[@]}"

step "3/8  Seeding app credentials into Secrets Manager"
./scripts/seed-eks-secret.sh

step "4/8  Pointing kubectl at the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

step "5/8  Building and pushing container images"
./scripts/build-push-ecr.sh

step "6/8  Syncing values.yaml from Terraform outputs"
./scripts/sync-values-from-tf.sh

# ArgoCD deploys whatever is on master, NOT what is on this disk. Bootstrapping it (step 8) while
# values.yaml is still uncommitted makes ArgoCD immediately revert the cluster to the OLD image tag
# -- which, after a rebuild, points at an image that does not exist in the fresh ECR, so every pod
# lands in ImagePullBackOff. Observed on the 2026-07-20 rebuild. Commit before ArgoCD exists.
if ! git diff --quiet -- charts/voteball/values.yaml; then
  echo "values.yaml changed — committing so ArgoCD deploys these values, not the stale ones."
  git add charts/voteball/values.yaml
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

step "7/8  Installing the app"
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
kubectl rollout status deployment/backend  -n devops-app --timeout=300s
kubectl rollout status deployment/frontend -n devops-app --timeout=300s
kubectl rollout status deployment/worker   -n devops-app --timeout=300s

step "8/8  Bootstrapping ArgoCD (GitOps takes over from here)"
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
