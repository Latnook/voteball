#!/usr/bin/env bash
# Full ordered teardown. Stops before `terraform destroy` so you confirm it yourself.
#
# Order matters and is the reason this script exists:
#   1. ArgoCD Application first  -- selfHeal:true would otherwise recreate everything we delete.
#   2. Ingress next              -- lets external-dns remove its DNS records and the ALB
#                                   de-provision. A leftover ALB's ENIs block VPC deletion.
#   3. Wait for the ALB to go    -- polling, because deletion is asynchronous.
#   4. terraform destroy last.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

REGION="il-central-1"
TFVARS="voteball-eks.tfvars"

# Terraform prompts for confirmation by default -- that is the intended behaviour for a human at a
# terminal. Set VOTEBALL_AUTO_APPROVE=1 only for unattended/automated runs.
APPROVE=()
[ "${VOTEBALL_AUTO_APPROVE:-0}" = "1" ] && APPROVE=(-auto-approve)

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "1/5  Removing the ArgoCD Application (stops selfHeal fighting the teardown)"
kubectl delete -f argocd/voteball-application.yaml --ignore-not-found

step "2/5  Removing the Ingress (releases the ALB and the DNS records)"
kubectl delete ingress voteball -n devops-app --ignore-not-found

step "3/5  Waiting for the ALB to de-provision (its ENIs block VPC deletion)"
for _ in $(seq 1 60); do
  remaining="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-devopsap-voteball')].LoadBalancerName" \
    --output text 2>/dev/null || echo "")"
  if [ -z "$remaining" ] || [ "$remaining" = "None" ]; then
    echo "ALB gone."
    break
  fi
  echo "  still present ($remaining) — waiting 10s"
  sleep 10
done

step "4/5  Uninstalling the Helm release"
helm uninstall voteball -n devops-app --ignore-not-found || true

step "5/5  Destroying AWS infrastructure (Terraform will ask you to confirm)"
terraform -chdir=terraform-eks destroy -var-file="$TFVARS" "${APPROVE[@]}"

cat <<'EOF'

Teardown complete. A final DB snapshot was taken -- the next deploy restores from it automatically.

  If destroy hung uninstalling a helm_release ("context deadline exceeded"), Helm cannot cleanly
  uninstall while the cluster is being deleted. Drop that release from state and re-run; it dies
  with the cluster anyway:
      terraform -chdir=terraform-eks state rm helm_release.<name>
      ./scripts/destroy.sh
EOF
