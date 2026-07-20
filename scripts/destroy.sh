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

# This script must be safe to re-run after a partial teardown, when the cluster may already be gone.
# In that state kubectl fails with "Unauthorized"/"connection refused" rather than "not found", which
# --ignore-not-found does NOT cover, so set -e would abort before reaching Terraform. Any leftover
# Kubernetes object dies with the cluster anyway; these steps are best-effort by design.
if kubectl cluster-info >/dev/null 2>&1; then
  step "1/6  Removing the ArgoCD Application (stops selfHeal fighting the teardown)"
  kubectl delete -f argocd/voteball-application.yaml --ignore-not-found || true

  step "2/6  Removing the Ingress (releases the ALB and the DNS records)"
  kubectl delete ingress voteball -n devops-app --ignore-not-found || true
else
  step "1-2/6  Cluster unreachable — skipping ArgoCD/Ingress deletion (already gone)"
fi

step "3/6  Waiting for the ALB to de-provision (its ENIs block VPC deletion)"
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

step "4/6  Uninstalling the Helm release"
if kubectl cluster-info >/dev/null 2>&1; then
  helm uninstall voteball -n devops-app --ignore-not-found || true
else
  echo "Cluster unreachable — skipping (the release dies with the cluster)."
fi

step "5/6  Removing this cluster's DNS records"
# Deterministic backstop: external-dns only reconciles on a timer, so teardown can destroy it before
# it notices the deleted Ingress, stranding voteball.latnook.com on a dead ALB (2026-07-20). This
# waits for external-dns to do its own job, then removes whatever it left behind. Only touches
# records whose ownership TXT names this cluster.
./scripts/cleanup-stale-dns.sh || echo "WARNING: DNS cleanup failed; check the zone by hand."

step "6/6  Destroying AWS infrastructure (Terraform will ask you to confirm)"
terraform -chdir=terraform-eks destroy -var-file="$TFVARS" "${APPROVE[@]}"

cat <<'EOF'

Teardown complete. A final DB snapshot was taken -- the next deploy restores from it automatically.

  If destroy hung uninstalling a helm_release ("context deadline exceeded"), Helm cannot cleanly
  uninstall while the cluster is being deleted. Drop that release from state and re-run; it dies
  with the cluster anyway:
      terraform -chdir=terraform-eks state rm helm_release.<name>
      ./scripts/destroy.sh
EOF
