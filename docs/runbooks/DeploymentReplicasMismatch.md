# DeploymentReplicasMismatch

**A Deployment somewhere in the cluster has had fewer ready replicas than desired for 10 minutes.**

## What this means

This alert is cluster-wide — it covers every namespace (`devops-app`, `ci`, `argocd`, `observability`),
not just the voteball app. It fires when a Deployment says it wants N pods but fewer than N have been
ready for a sustained 10 minutes. The most common cause by far is a rollout that started and never
finished — the new pods aren't becoming ready, so Kubernetes is stuck between old and new.

## What to check first

The alert's labels tell you which Deployment and namespace — check those first rather than guessing:

```bash
# alert annotation shows {{ namespace }}/{{ deployment }} — substitute them here
kubectl get deploy -n <namespace> <deployment>
kubectl get pods -n <namespace> -l app=<deployment>
kubectl rollout status deploy/<deployment> -n <namespace>
```

`kubectl rollout status` will tell you directly whether it's mid-rollout and stuck, or just short on
capacity.

## How to fix it

- **If it's `devops-app/backend` or `devops-app/worker`** — this overlaps with
  `VoteballPodCrashLooping`/`VoteballNoBackendAvailable`; follow those runbooks, they're more specific
  to this application.
- **If it's a platform Deployment (`argocd`, `observability`, `ci`)** — check `kubectl describe pod` for
  the same causes as any pod: image pull failure, insufficient node capacity (see
  `NodeNotReadyOrUnderPressure`), or a crash loop. These Deployments are managed by Terraform
  (`helm_release`), not by application deploys — a bad config there needs a `terraform apply` fix, not
  an ArgoCD rollback.
- **Stuck rollout, otherwise healthy pods** — `kubectl rollout status` hanging with old pods still
  serving usually means the new pod's readiness probe is failing. Check its logs directly.

## When to roll back instead

For `devops-app` Deployments, follow `VoteballNoBackendAvailable`'s rollback guidance (revert
`image.tag` in `charts/voteball/values.yaml`). For a platform Deployment, there is no equivalent
`values.yaml` — the fix is whatever Terraform/Helm change caused it, reverted the same way (git revert
the `.tf` or chart change, then `terraform apply`).
