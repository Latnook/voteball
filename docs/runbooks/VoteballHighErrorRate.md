# VoteballHighErrorRate

**More than 5% of voting-journey requests are returning 5xx, for 5 minutes.**

## What this means

Visitors are being failed. The site may still *look* fine — `/health` is a static response and the
liveness probe is a bare TCP check, so neither touches the database. Pods stay `Ready` while every API
call fails. That gap is exactly why this alert exists.

## What to check first

```bash
kubectl get pods -n devops-app
kubectl logs -n devops-app -l app=backend --tail=50 | grep -i error
```

Then which endpoint is failing, and whether it is the database:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# in the UI at localhost:9090, run:
#   sum by (endpoint, status) (rate(voteball_http_requests_total{status=~"5.."}[5m]))
#   rate(voteball_db_errors_total[5m])
```

A non-zero `voteball_db_errors_total` means the backend cannot reach RDS. That is a different problem
from application errors, and the fix is different.

## How to fix it

- **Database unreachable** — check the RDS instance is available in the AWS console, and that
  `allow-db-egress` still permits it: `kubectl get networkpolicy -n devops-app allow-db-egress -o yaml`.
- **A bad release** — compare the running build against the last known good:
  `kubectl get deploy -n devops-app backend -o jsonpath='{.spec.template.spec.containers[0].image}'`.
  If it changed recently, roll back (below).
- **One bad pod** — if only one backend pod is erroring, delete it; the Deployment replaces it.

## When to roll back instead

If the error rate started within minutes of a deploy, roll back first and diagnose afterwards. Revert
`image.tag` in `charts/voteball/values.yaml` to the previous `ci: image tag` commit's value and push;
ArgoCD syncs it. Do not spend the outage reading logs.
