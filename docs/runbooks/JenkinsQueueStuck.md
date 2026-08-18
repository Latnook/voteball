# JenkinsQueueStuck

**Jenkins' build queue has been non-empty for 15 minutes.**

## What this means

Builds are queued and nothing is picking them up. **The public website is unaffected either way** — CI
being stuck never takes down the live site, since ArgoCD/the running pods have no dependency on
Jenkins. What it does mean: nobody's code changes are being tested or deployed until this clears, and
`application-cd` can't promote anything new either.

Note Jenkins runs as a StatefulSet (`sts/jenkins`), not a Deployment — some `kubectl` commands differ
slightly from the app's pods.

## What to check first

```bash
kubectl get pods -n ci
kubectl get sts -n ci jenkins
```

Then look at the queue itself via the Jenkins UI:

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080
# browse http://localhost:8080/queue
```

The queue page shows *why* each item is stuck — usually "Waiting for next available executor" — which
tells you immediately whether it's an agent-scheduling problem or something queue-specific.

## How to fix it

- **No agent pod can be scheduled** — the most common cause. Jenkins provisions agent pods on demand
  in `ci`; check `kubectl get pods -n ci` for a pending agent pod and `kubectl describe` it for why
  (usually the same node-capacity issue as `NodeNotReadyOrUnderPressure`, since these pods land on
  Spot too).
- **Jenkins controller itself is unhealthy** — `kubectl get sts -n ci jenkins` and
  `kubectl logs -n ci jenkins-0 -c jenkins --tail=50`. A controller that's up but slow to respond can
  still show a growing queue.
- **A specific build is genuinely wedged** (not just slow to start) — this metric
  (`jenkins_queue_size_value`) counts anything queued, including a build that's actually running but
  the queue accounting hasn't cleared. If the Jenkins UI shows one item stuck for a long time with
  no agent activity, cancel that build from the UI and see if the queue drains.
- **If this alert fires often on normal build bursts** — `jenkins_queue_size_value` counts the whole
  queue, so several builds landing at once can trip a noisy alert even though everything is draining
  fine. `jenkins_queue_stuck_value` is Jenkins' own narrower signal for a task that genuinely cannot be
  scheduled at all, and is the tighter alternative — switch `queueMetric` in
  `charts/observability/values.yaml` if this proves noisy in practice.

## When to roll back instead

There's nothing to roll back — this is a CI/CD platform alert, not an application one. If a recent
change to `ci/jenkins/jenkins.yaml` or `terraform/addon-jenkins.tf` caused this (e.g. an agent pod
template that no longer schedules), revert that commit and run `terraform apply` again — remember
that a Jenkins config change only takes effect through `terraform apply`, not by committing alone.
