# NodeNotReadyOrUnderPressure

**A node has been `NotReady`, or under memory/disk pressure, for 10 minutes.**

## What this means

The node group is 100% Spot, so nodes disappearing is routine — AWS reclaims a Spot instance with two
minutes' notice, the Node Termination Handler drains it, and the Cluster Autoscaler brings up a
replacement, usually within a few minutes. This alert is deliberately set to 10 minutes specifically
*because* a brief `NotReady` is normal and not worth waking anyone for; ten minutes is not normal.

**Important: for a routine Spot reclaim, the correct action is to wait and confirm the autoscaler
replaced the node — not to try to fix the node itself.** A reclaimed Spot instance is gone; there is
nothing to repair on it.

## What to check first

```bash
kubectl get nodes
kubectl describe node <node-name> | tail -30
```

The `Events` section at the bottom of `describe` tells you which case you're in — a `NodeNotReady`
event with no corresponding `TerminateSpotInstance`/drain event nearby is the case that actually needs
attention.

## How to fix it

- **Node was Spot-reclaimed and a replacement is already `Ready`** — nothing to do. Confirm with
  `kubectl get nodes` that pod counts match expectations again, then let the alert clear on its own.
- **Node is `NotReady` and no replacement has appeared after ~10 minutes** — check the Cluster
  Autoscaler's own logs for why it hasn't scaled:
  ```bash
  kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50
  ```
  Common cause: hitting the node group's max size, or a Spot capacity shortage in this instance type/AZ
  — both are visible in that log.
- **Node is `Ready` but under `MemoryPressure`/`DiskPressure`** — this is not Spot churn, it's a real
  resource problem on a live node. Check what's running on it (`kubectl describe node` lists pods) and
  whether one of them is the cause (see `VoteballContainerOOMKilled` if it's a voteball pod).

## When to roll back instead

There is nothing to roll back — this alert is about cluster infrastructure, not the application
release. If a node genuinely won't come back and the autoscaler is stuck, that's a Terraform/node-group
configuration question (`terraform/`), not something a `values.yaml` revert touches.
