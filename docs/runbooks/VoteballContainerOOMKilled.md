# VoteballContainerOOMKilled

**A pod in `devops-app` has restarted more than 3 times in an hour.**

## What this means

Memory limits on `backend`/`worker` are set tight on purpose so that a leak or a spike gets noticed
quickly rather than silently degrading the node for everything else on it. This alert is how you find
out the limit was hit, rather than noticing weeks later that a pod has quietly been restarting.
Repeated restarts *without* `CrashLoopBackOff` (see `VoteballPodCrashLooping` if it's that) usually
means `OOMKilled` or a failing liveness probe — both look the same from this alert's perspective.

## What to check first

```bash
kubectl get pods -n devops-app
kubectl describe pod -n devops-app <pod-name> | grep -A3 "Last State"
```

Look for `Reason: OOMKilled` specifically — that confirms memory, not the liveness probe, is the
cause. If it says `Reason: Error` instead, check the liveness probe path for that container
(`backend`: TCP on 5000; `worker`: heartbeat file staleness) rather than memory.

## How to fix it

- **Confirmed OOMKilled, isolated pod** — restart already happened automatically; no action needed
  beyond watching whether it recurs. One restart from a transient spike is not a pattern.
- **OOMKilled and recurring** — the memory limit is genuinely too tight for real traffic. Raise
  `resources.limits.memory` for that container in `charts/voteball/values.yaml`, commit, and push.
  This is a normal, safe change — it doesn't touch application code.
- **OOMKilled and it keeps climbing even after raising the limit** — that's a real leak, not a
  sizing problem. Check whether it correlates with a specific recent code change (`git log` on
  `services/backend/` or `services/worker/` around when restarts started).

## When to roll back instead

If the restarts started right after a deploy and raising the memory limit doesn't stop them within a
restart or two, treat it as a leak introduced by that release: revert `image.tag` in
`charts/voteball/values.yaml` to the previous `ci: image tag` commit's value and push. Don't spend
hours raising limits repeatedly to chase a real leak — that just delays the fix and burns more memory
on the node in the meantime.
