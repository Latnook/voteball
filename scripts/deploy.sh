#!/usr/bin/env bash
# Full ordered deploy. Stops before `terraform apply` so you confirm the (billed) change yourself.
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

REGION="il-central-1"
CLUSTER="voteball"
TFVARS="voteball-eks.tfvars"

# Terraform prompts for confirmation by default -- that is the intended behaviour for a human at a
# terminal. Set VOTEBALL_AUTO_APPROVE=1 only for unattended/automated runs.
APPROVE=()
[ "${VOTEBALL_AUTO_APPROVE:-0}" = "1" ] && APPROVE=(-auto-approve)

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if [ ! -f "terraform-eks/$TFVARS" ]; then
  echo "ERROR: terraform-eks/$TFVARS is missing (see docs/deploy.md, One-time setup)." >&2
  exit 1
fi

step "1/8  Resolving the newest DB snapshot"
./scripts/find-latest-snapshot.sh

step "2/8  Building AWS infrastructure (Terraform will ask you to confirm)"
echo "This creates real, billed resources (~\$200/month while up)."
terraform -chdir=terraform-eks init -upgrade
terraform -chdir=terraform-eks apply -var-file="$TFVARS" "${APPROVE[@]}"

step "3/8  Seeding app credentials into Secrets Manager"
./scripts/seed-eks-secret.sh

step "4/8  Pointing kubectl at the cluster"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

step "5/8  Building and pushing container images"
./scripts/build-push-ecr.sh

step "6/8  Syncing values.yaml from Terraform outputs"
./scripts/sync-values-from-tf.sh

step "7/8  Installing the app"
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
kubectl rollout status deployment/backend  -n devops-app --timeout=300s
kubectl rollout status deployment/frontend -n devops-app --timeout=300s
kubectl rollout status deployment/worker   -n devops-app --timeout=300s

step "8/8  Bootstrapping ArgoCD (GitOps takes over from here)"
kubectl apply -f argocd/voteball-application.yaml

cat <<'EOF'

Deploy complete.

  If values.yaml changed in step 6, commit it -- ArgoCD syncs from master:
      git add charts/voteball/values.yaml && git commit -m "Deploy: sync values" && git push

  Verify:
      kubectl get pods -n devops-app
      curl -sf https://voteball.latnook.com/api/options | head -c 120

  DNS can take a minute to propagate after a rebuild.
EOF
