#!/usr/bin/env bash
# Full ordered teardown. Stops before `terraform destroy` so you confirm it yourself.
#
# Order matters and is the reason this script exists:
#   1. Both ArgoCD Applications first (voteball, observability) -- selfHeal:true on either would
#      otherwise recreate everything we delete.
#   2. Ingress next              -- lets external-dns remove its DNS records and the ALB
#                                   de-provision. A leftover ALB's ENIs block VPC deletion.
#   3. Wait for the ALB to go    -- polling, because deletion is asynchronous.
#   4. Uninstall Helm releases   -- while the cluster is still healthy (see step 4 below for why).
#      This now includes kube-prometheus-stack, which removes the Prometheus/Alertmanager custom
#      resources the prometheus-operator reconciles -- see step 5 below for why that has to happen
#      BEFORE the PVC delete, not after.
#   5. Delete the observability PVCs -- a StatefulSet's volumeClaimTemplate survives `helm uninstall`
#      by design, and the gp3 StorageClass's reclaim policy is Delete, so this is what actually removes
#      the underlying EBS volume. Must run AFTER step 4, once the operator can no longer recreate the
#      StatefulSet it belongs to.
#   6. DNS cleanup backstop.
#   7. terraform destroy last, with one bounded automatic retry if it hits either of the two hangs
#      documented in CLAUDE.md's teardown section (a Helm uninstall racing cluster deletion, and the
#      second-order External Secrets finalizer hang that follows it) -- see step 7 for the detail.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

. scripts/lib/config.sh
TFVARS="voteball.tfvars"
CLUSTER_TAG="${CLUSTER}*" # VPC Name tag, used to scope the orphaned-ENI reaper below

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
  step "1/7  Removing the ArgoCD Applications (stops selfHeal fighting the teardown)"
  # ALL THREE Applications, not just voteball's. `argocd/voteball-application.yaml.tmpl` also
  # declares `observability`, and `charts/logging`'s own Application declares `logging` -- both carry
  # the same `prune: true, selfHeal: true` -- leaving either running survives this step and keeps
  # recreating its chart's objects (NetworkPolicies including default-deny, dashboard ConfigMaps,
  # PrometheusRule, or the Elasticsearch/Kibana CRs) into a namespace mid-teardown.
  #
  # Deleted BY NAME, not by rendering the template. Teardown must not depend on `terraform output`
  # being readable: this script runs against half-destroyed stacks, and a render failure here would
  # skip the deletion and leave selfHeal recreating everything the next five steps remove. The names
  # and namespace are fixed in the template, so nothing environment-specific is needed to say which.
  kubectl delete application voteball -n argocd --ignore-not-found || true
  kubectl delete application observability -n argocd --ignore-not-found || true
  kubectl delete application logging -n argocd --ignore-not-found || true

  step "2/7  Removing the Ingresses (releases the ALB and the DNS records)"
  # ALL THREE Ingresses, not just the app's. Since 2026-07-31 devops-app/voteball and
  # ci/jenkins-webhook share ALB group "voteball" (alb.ingress.kubernetes.io/group.name), and since
  # the EFK logging pass logging/kibana joined as the third member -- an ALB is only de-provisioned
  # when its group has NO members left. Deleting some and not all of them leaves the ALB alive, so
  # step 3 waits out its full timeout and `terraform destroy` then hits DependencyViolation on subnet
  # deletion because the ALB's ENIs are still attached -- the 10-20 minute hang this script exists to
  # prevent. This is why the kibana Ingress is deleted HERE and not left to step 4's
  # `helm uninstall logging` -- that runs AFTER step 3 already starts waiting, which would be the
  # exact hang all over again for the group's third member.
  kubectl delete ingress voteball -n devops-app --ignore-not-found || true
  kubectl delete ingress jenkins-webhook -n ci --ignore-not-found || true
  kubectl delete ingress kibana -n logging --ignore-not-found || true
else
  step "1-2/7  Cluster unreachable — skipping ArgoCD/Ingress deletion (already gone)"
fi

step "3/7  Waiting for the ALB to de-provision (its ENIs block VPC deletion)"
# TWO name shapes are matched on purpose. The AWS Load Balancer Controller names an ALB after the
# INGRESS GROUP when one is set (k8s-<group>-<hash>, i.e. k8s-voteball-...) and after the
# namespace+ingress when it is not (k8s-devopsap-voteball-...). Joining the group on 2026-07-31
# changed the name, and a filter matching only the old shape reports "ALB gone" INSTANTLY while the
# load balancer is still running -- a false negative that is worse than no check at all.
for _ in $(seq 1 60); do
  remaining="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-${CLUSTER}-') || starts_with(LoadBalancerName, 'k8s-devopsap-${CLUSTER}')].LoadBalancerName" \
    --output text 2>/dev/null || echo "")"
  if [ -z "$remaining" ] || [ "$remaining" = "None" ]; then
    echo "ALB gone."
    break
  fi
  echo "  still present ($remaining) — waiting 10s"
  sleep 10
done

step "4/7  Uninstalling Helm releases while the cluster is still healthy"
# All SIX of this stack's OWN helm_release resources -- voteball, jenkins, jenkins-support,
# kube-prometheus-stack, logging, and elastic-operator -- uninstalled explicitly HERE, before
# `terraform destroy` starts deleting the cluster underneath them. This is the actual fix for the
# 2026-08-04 hang, not a workaround for it:
# `terraform destroy` also runs `helm uninstall` internally when it gets to these resources, and THAT is
# what hung with "context deadline exceeded" -- Helm cannot cleanly uninstall a release from a cluster
# that is simultaneously being torn down. Doing the uninstall here, while every node and controller is
# still up, is the situation Helm actually expects; letting Terraform attempt it mid-deletion is the
# workaround, and this avoids needing one for these six releases.
#
# kube-prometheus-stack MUST be uninstalled HERE, before the PVC delete in the next step, not after.
# Uninstalling it removes the Prometheus and Alertmanager CUSTOM RESOURCES the prometheus-operator
# reconciles -- see step 5 below for what goes wrong if the PVCs are deleted (or the StatefulSets are
# deleted directly) while those CRs, and the operator watching them, are still around.
#
# external-secrets (the ExternalSecrets Operator / ESO) is DELIBERATELY NOT uninstalled here. Its
# controller has to stay alive until Terraform deletes the namespaces (ci, devops-app) that hold
# ExternalSecret/SecretStore custom resources -- those carry finalizers that only the ESO controller
# can clear. Pulling ESO out early just relocates the same class of hang to one step earlier, which is
# exactly what happened by hand on 2026-08-04: removing helm_release.external_secrets from state left
# the ci namespace's ExternalSecret/SecretStore finalizers with no controller left to clear them, and
# kubernetes_namespace.ci sat Terminating forever. Leaving ESO to Terraform's own destroy graph (it
# naturally uninstalls consumers before their dependencies) is the safer order; the retry logic in
# step 7 below is what recovers if it still hangs.
if kubectl cluster-info >/dev/null 2>&1; then
  # ECK comes out in a SPECIFIC ORDER: custom resources first, operator second.
  #
  # FINALIZERS are why. ECK attaches its own finalizers to the Elasticsearch/Kibana resources and to
  # the Secrets they own, and only the running operator removes them -- it is also what performs the
  # orderly shutdown that ECK's volumeClaimDeletePolicy depends on. Uninstall the operator first and
  # every Elasticsearch/Kibana delete sits Terminating with no controller left to clear it: exactly
  # the hang kubernetes_namespace.ci produced on 2026-08-04 with no ESO left to clear its children.
  #
  # It is NOT the ValidatingWebhookConfiguration, which is what this comment used to claim. Rendering
  # eck-operator 3.5.0 shows all 16 webhooks are `failurePolicy: Ignore` on
  # `operations: [CREATE, UPDATE]` -- DELETE is not intercepted, and an unreachable webhook is skipped
  # rather than blocking, so that mechanism cannot fire. The ORDER below is still correct; do not
  # "simplify" it on the strength of the webhook fact.
  #
  # ECK's volumeClaimDeletePolicy deletes the Elasticsearch PVC when the CR goes, so unlike the
  # observability PVCs in step 5 there is no orphaned-EBS cleanup to do here.
  kubectl delete elasticsearch --all -n logging --ignore-not-found --timeout=120s || true
  kubectl delete kibana        --all -n logging --ignore-not-found --timeout=120s || true
  helm uninstall logging          -n logging        --ignore-not-found || true
  helm uninstall elastic-operator -n elastic-system --ignore-not-found || true
  helm uninstall voteball              -n devops-app    --ignore-not-found || true
  helm uninstall jenkins               -n ci             --ignore-not-found || true
  helm uninstall jenkins-support       -n ci             --ignore-not-found || true
  helm uninstall kube-prometheus-stack -n observability  --ignore-not-found || true
else
  echo "Cluster unreachable — skipping (these releases die with the cluster)."
fi

if kubectl cluster-info >/dev/null 2>&1; then
  step "5/7  Deleting the observability PVCs"
  # A PVC created by a StatefulSet's volumeClaimTemplate is NOT removed by `helm uninstall` -- Kubernetes
  # deliberately keeps it so a recreated StatefulSet can re-bind its data. Left alone it becomes an
  # orphaned EBS volume that bills forever, and unlike a leftover ENI it blocks nothing, so
  # `terraform destroy` reports complete success while leaking it. The gp3 StorageClass's reclaim policy
  # is Delete, so removing the PVC here is what actually deletes the volume.
  #
  # This step now runs AFTER kube-prometheus-stack is uninstalled in step 4 above -- and that order is
  # load-bearing, not cosmetic. These PVCs belong to StatefulSets that are themselves owned by the
  # Prometheus and Alertmanager CUSTOM RESOURCES the prometheus-operator reconciles. An earlier version
  # of this script deleted the StatefulSet directly, with the operator (and those CRs) still running --
  # verified against the live cluster to NOT work: the operator notices its StatefulSet is gone and
  # recreates it from the CR within seconds, and the StatefulSet controller then recreates the missing
  # PVC from volumeClaimTemplates, dynamically provisioning a BRAND-NEW 10Gi EBS volume that nothing
  # downstream deletes. That is the guaranteed outcome of deleting a StatefulSet while the thing that
  # owns it is still alive, not a race -- and it is exactly the leak this step exists to prevent, which
  # is why the StatefulSet delete is gone rather than reordered. Removing the kube-prometheus-stack
  # release in step 4 deletes the Prometheus/Alertmanager CRs themselves, so the operator has nothing
  # left to reconcile and cannot recreate anything; their StatefulSets (and pods) go away as a normal
  # consequence of that release removal, which also clears the pvc-protection finalizer that would
  # otherwise block this delete while a pod still had the volume mounted. --timeout/|| true below tolerate
  # any brief lag in that cascade finishing, the same tolerance used everywhere else in this script.
  #
  # || true throughout: a cluster that is already gone, or was never built with this stack, must not
  # fail the teardown.
  kubectl delete pvc --all -n observability --ignore-not-found --timeout=60s || true
else
  step "5/7  Cluster unreachable — skipping observability PVC cleanup (these volumes die with the cluster)"
fi

step "6/7  Removing this cluster's DNS records"
# Deterministic backstop: external-dns only reconciles on a timer, so teardown can destroy it before
# it notices the deleted Ingress, stranding the app's DNS on a dead ALB (2026-07-20). This
# waits for external-dns to do its own job, then removes whatever it left behind. Only touches
# records whose ownership TXT names this cluster.
./scripts/cleanup-stale-dns.sh || echo "WARNING: DNS cleanup failed; check the zone by hand."

step "7/7  Destroying AWS infrastructure (Terraform will ask you to confirm)"

# When nodes terminate, the AWS VPC CNI can leave DETACHED (status=available) aws-K8S-* interfaces
# behind. Terraform then retries DeleteSubnet against a DependencyViolation until it times out --
# this stalled the 2026-07-20 teardown for ~10 minutes, and deleting the one orphan by hand let the
# subnet drop immediately. Reap them in the background while destroy runs, rather than waiting for
# Terraform to fail and retrying.
#
# Safety: only interfaces that are BOTH detached (status=available) and CNI-created
# (Description starts with aws-K8S-) inside this stack's VPC. A detached CNI interface is garbage by
# definition -- anything still in use reports status=in-use and is never considered.
reap_orphaned_enis() {
  while true; do
    sleep 30
    vpc="$(aws ec2 describe-vpcs --region "$REGION" \
      --filters "Name=tag:Name,Values=${CLUSTER_TAG}" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo None)"
    [ "$vpc" = "None" ] && continue
    [ -z "$vpc" ] && continue
    for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$vpc" Name=status,Values=available \
        --query "NetworkInterfaces[?starts_with(Description,'aws-K8S-')].NetworkInterfaceId" \
        --output text 2>/dev/null); do
      echo "  reaping orphaned CNI interface $eni (detached; was blocking subnet deletion)"
      aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null || true
    done
  done
}

reap_orphaned_enis &
REAPER_PID=$!

# Second background job, alongside the reaper: narrates what AWS is actually doing while
# `terraform destroy` sits on "Still destroying...". Teardown is the better-instrumented half --
# the final snapshot reports a real PercentProgress, and the ENI count this watcher prints is
# precisely what blocks DeleteSubnet, so the 10-20 minute subnet stall becomes legible instead of
# alarming. Strictly read-only (describe*/list* only); the reaper above is the mutating one.
WATCH_PID=""
if [ "${VOTEBALL_NO_WATCH:-0}" != "1" ]; then
  ./scripts/watch-aws-progress.sh destroy &
  WATCH_PID=$!
fi

DESTROY_LOG="$(mktemp)"
# ONE trap, killing both jobs. A second `trap ... EXIT` would silently REPLACE this one and leak
# the reaper -- traps do not stack.
cleanup() {
  kill "$REAPER_PID" 2>/dev/null || true
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
  rm -f "$DESTROY_LOG"
}
trap cleanup EXIT

# Runs `terraform destroy`, streaming it live to the terminal (never buffer a long-running infra
# command -- a masked exit code can report a failed run as success) while also capturing it to
# $DESTROY_LOG so the caller can inspect the failure text afterwards. `set -o pipefail` (part of the
# shebang's `set -euo pipefail`) makes the function's exit status reflect terraform's, not tee's.
destroy_attempt() {
  : >"$DESTROY_LOG"
  terraform -chdir=terraform destroy -var-file="$TFVARS" "${APPROVE[@]}" 2>&1 | tee "$DESTROY_LOG"
}

DESTROY_OK=0
destroy_attempt && DESTROY_OK=1

if [ "$DESTROY_OK" = 0 ] && grep -q "Error acquiring the state lock" "$DESTROY_LOG"; then
  # A stale lock left by an interrupted previous run (Ctrl-C, a timeout) -- OR a lock legitimately
  # held by another operator who is mid-apply right now. This script cannot tell those two apart, and
  # force-unlocking the second case can corrupt state, so it deliberately does NOT clear the lock
  # automatically. It prints the exact recovery instead, with the lock id parsed out of Terraform's
  # own error output when possible.
  lock_id="$(sed -n 's/^[[:space:]]*ID:[[:space:]]*//p' "$DESTROY_LOG" | head -1)"
  account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "<account id>")"
  step "Destroy stopped: the Terraform state lock is held"
  cat <<EOF

Before retrying, confirm no one else (including a previous run of this script, or Terraform running
somewhere else) is genuinely still applying or destroying this stack. If you're sure the lock is
stale -- the usual cause is this script or "terraform apply" being interrupted by Ctrl-C or a
timeout -- clear it and re-run:

  Lock file:  s3://${CLUSTER}-tfstate-${account_id}/voteball/main.tfstate.tflock
  Lock ID:    ${lock_id:-<see "Error acquiring the state lock" above for the ID>}

  terraform -chdir=terraform force-unlock ${lock_id:-<LOCK_ID>}
  ./scripts/destroy.sh

If it is NOT stale -- someone else really is running Terraform -- wait for that run to finish instead.
EOF
  exit 1
fi

if [ "$DESTROY_OK" = 0 ]; then
  step "Destroy failed — retrying once after dropping cluster-bound resources from state"
  cat <<'EOF'

The most common cause (hit for real on 2026-08-04) is "context deadline exceeded": Helm cannot
cleanly uninstall a release, or Kubernetes cannot clear a finalizer, while the EKS control plane is
simultaneously being deleted underneath it -- first on helm_release.jenkins, then (second-order, once
external-secrets' controller was gone) on kubernetes_namespace.ci, whose ExternalSecret/SecretStore
child resources had finalizers nothing was left alive to clear. Both kinds of resource die with the
cluster regardless of whether Terraform got to clean them up first, so forgetting Terraform ever
created them loses nothing -- unlike an AWS resource, which would keep existing (and billing) with no
record left to find it by.

That is why this only ever drops resources matching EXACTLY two prefixes -- helm_release. and
kubernetes_ -- and NEVER touches anything else, in particular never an aws_* address. See the filter
below if you want to check it yourself; it is intentionally an allowlist, not a blocklist.
EOF

  mapfile -t all_resources < <(terraform -chdir=terraform state list 2>/dev/null || true)
  # Matches "helm_release.<name>" or "kubernetes_<anything>.<name>", each optionally followed by an
  # index ([0]) and optionally preceded by a module path (module.foo.helm_release.bar). Anchored on
  # the resource-type boundary (a literal "." or start-of-string right before the type, and a "."
  # right after it) so it can only ever match those two exact type prefixes -- never, for example, an
  # unrelated type that merely contains "kubernetes_" or "helm_release" as a substring, and never any
  # aws_* type, which does not start with either prefix.
  RM_FILTER='(^|\.)(helm_release|kubernetes_[a-zA-Z0-9_]+)\.[^.]+(\[[0-9]+\])?$'
  mapfile -t to_remove < <(printf '%s\n' "${all_resources[@]}" | grep -E "$RM_FILTER" || true)

  if [ "${#to_remove[@]}" -eq 0 ]; then
    echo "No helm_release.* or kubernetes_* resources remain in state -- nothing safe to drop."
    echo "The failure above is something else; investigate the captured output by hand."
    exit 1
  fi

  echo "Dropping ${#to_remove[@]} resource(s) from state (they die with the cluster regardless):"
  for addr in "${to_remove[@]}"; do
    echo "  $addr"
    terraform -chdir=terraform state rm "$addr" || echo "    (state rm failed -- continuing anyway)"
  done

  step "Retrying terraform destroy (final attempt — this script retries exactly once)"
  DESTROY_OK=0
  destroy_attempt && DESTROY_OK=1

  if [ "$DESTROY_OK" = 0 ]; then
    cat <<'EOF'

Retry also failed. The resources listed above are dropped from state either way, so they are gone or
going regardless of what Terraform thinks now -- what's in the output above is the real remaining
problem. Investigate it directly; this script does not retry a second time on purpose (an unbounded
retry loop here could silently drop state forever without ever surfacing a genuine, unrelated
failure). See CLAUDE.md's teardown section for the background on both known hangs.
EOF
    exit 1
  fi
fi

cat <<'EOF'

Teardown complete. A final DB snapshot was taken -- the next deploy restores from it automatically.
EOF
