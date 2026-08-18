# VoteballPodCrashLooping

**A pod in `devops-app` has been in `CrashLoopBackOff` for 5 minutes.**

## What this means

A container is starting, failing, and being restarted by Kubernetes over and over. Which pod matters —
a crash-looping `backend` or `worker` pod eats into capacity and can trip `VoteballNoBackendAvailable`
or `VoteballRollupsStale` next; a crash-looping `frontend` pod is less urgent since the others cover
the ALB in the meantime.

## What to check first

```bash
kubectl get pods -n devops-app
kubectl describe pod -n devops-app <pod-name>
kubectl logs -n devops-app <pod-name> --previous
```

`--previous` is the important flag — the current container instance may not have logged anything yet,
but the one that just crashed did. `kubectl describe` also shows the last termination reason
(`Error`, `OOMKilled`, etc.) near the bottom, which tells you which of the causes below applies before
you read a single log line.

## How to fix it

- **Bad config or missing secret** — a container that crashes immediately on every restart (not after
  running for a while) usually means it can't read its config. Check
  `kubectl get configmap -n devops-app app-config -o yaml` and
  `kubectl get secret -n devops-app app-secret -o yaml` (the values are base64, not readable, but
  confirm the keys the pod expects are present).
- **OOMKilled** — `kubectl describe pod` shows `Last State: Terminated, Reason: OOMKilled`. See
  `VoteballContainerOOMKilled`'s runbook; the fix is the same (raise the memory limit or find the leak).
- **A bad release** — if this started right after a deploy, it's very likely the new image itself
  crashing on startup. Check the image tag against the last known good one (below) and roll back.

## When to roll back instead

If the crash loop started within minutes of a deploy, don't debug live — roll back. Revert `image.tag`
in `charts/voteball/values.yaml` to the previous `ci: image tag` commit's value and push; ArgoCD syncs
it. If the crash loop is isolated to a single pod with older pods still healthy, deleting that one pod
(`kubectl delete pod -n devops-app <pod-name>`) may be enough — the Deployment replaces it — without
touching the release at all.
