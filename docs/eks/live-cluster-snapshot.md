# Live cluster snapshot (evidence for README.submission.md)

**This file is four captures stacked in chronological order**, each from a different build of the
cluster. Nothing is overwritten when a new one is added — the older layers are the record:

| Layer | Heading it starts at | Build captured |
|---|---|---|
| 1 | (top of file) | the 2026-07-20 build |
| 2 | *Additions captured 2026-07-21* | the 2026-07-21 build, after the WAF / alerting / migration-Job pass |
| 3 | *2026-07-27 — pre-teardown capture* | the build then running, immediately before a deliberate `destroy.sh` |
| 4 | *2026-07-27 — post-rebuild capture* | the cluster `deploy.sh` rebuilt minutes later |

Layers 3 and 4 are a **matched pair either side of one teardown/rebuild cycle**, and comparing them is
the point: the vote count is identical across it. Their raw, untrimmed command output is in
[`evidence/`](evidence/).

> **This is dated evidence, not a description of the cluster as it stands now.** Every value here was
> true when captured and is deliberately left frozen. The cluster has been destroyed and rebuilt
> several times since layer 1, and each rebuild regenerates the ACM certificate, the WAF ACL, the
> cluster endpoint, the ALB name and every pod name — so identifiers in the older layers (e.g. the WAF
> id `bf57cc07-…`) no longer resolve. **That is the file working as intended, not rot.** For current
> values run `terraform -chdir=terraform output`; do not "correct" the captures to match, or this
> stops being a record of anything.
>
> *(Header last reconciled with the body on 2026-07-29, when it still described only layers 1–2. The
> live cluster on that date was the layer-4 build, still running — node age 2d7h, EKS v1.34.9.)*

## `kubectl get nodes`
```
NAME                                           STATUS   ROLES    AGE     VERSION
ip-10-0-44-88.il-central-1.compute.internal    Ready    <none>   6m46s   v1.34.9-eks-8f14419
ip-10-0-49-247.il-central-1.compute.internal   Ready    <none>   6m46s   v1.34.9-eks-8f14419
```

## `kubectl get namespaces`
```
NAME                STATUS   AGE
amazon-cloudwatch   Active   5m46s
argocd              Active   8m13s
default             Active   11m
devops-app          Active   3m23s
external-secrets    Active   8m11s
kube-node-lease     Active   11m
kube-public         Active   11m
kube-system         Active   11m
monitoring          Active   5m38s
```

## `kubectl get pods -n devops-app`
```
NAME                        READY   STATUS    RESTARTS   AGE
backend-5dc97c458d-nls96    1/1     Running   0          3m23s
backend-5dc97c458d-zfzt5    1/1     Running   0          3m23s
frontend-6866cb9ccb-5srlw   1/1     Running   0          3m24s
frontend-6866cb9ccb-bchlc   1/1     Running   0          3m23s
worker-9b677f49c-sq4dl      1/1     Running   0          3m24s
```

## `kubectl get deployments -n devops-app`
```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
backend    2/2     2            2           3m24s
frontend   2/2     2            2           3m24s
worker     1/1     1            1           3m24s
```

## `kubectl get services -n devops-app`
```
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
backend    ClusterIP   172.20.161.97   <none>        5000/TCP   3m25s
frontend   ClusterIP   172.20.86.217   <none>        80/TCP     3m25s
```

## `kubectl get ingress -n devops-app`
```
NAME       CLASS   HOSTS                  ADDRESS                                                                      PORTS   AGE
voteball   alb     voteball.latnook.com   k8s-devopsap-voteball-6fb18c0744-1887088313.il-central-1.elb.amazonaws.com   80      3m25s
```

## `kubectl get hpa,pdb,cronjob,networkpolicy -n devops-app`
```
NAME                                          REFERENCE            TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/backend   Deployment/backend   cpu: 9%/70%   2         5         2          3m25s

NAME                                  MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/backend    1               N/A               1                     3m25s
poddisruptionbudget.policy/frontend   1               N/A               1                     3m25s

NAME                            SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
cronjob.batch/voteball-backup   0 2 * * *   <none>     False     0        <none>          3m25s

NAME                                                        POD-SELECTOR                              AGE
networkpolicy.networking.k8s.io/allow-alb-to-frontend       app=frontend                              3m25s
networkpolicy.networking.k8s.io/allow-app-egress            app in (backend,backup,frontend,worker)   3m25s
networkpolicy.networking.k8s.io/allow-dns-egress            <none>                                    3m25s
networkpolicy.networking.k8s.io/allow-frontend-to-backend   app=backend                               3m25s
networkpolicy.networking.k8s.io/default-deny                <none>                                    3m25s
```

## `kubectl get serviceaccounts -n devops-app -o custom-columns=NAME:.metadata.name,IRSA-ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn`
```
NAME       IRSA-ROLE
backend    <none>
backup     arn:aws:iam::590183895228:role/voteball-backup-irsa
default    <none>
frontend   <none>
worker     arn:aws:iam::590183895228:role/voteball-worker-irsa
```

## `kubectl get externalsecret -n devops-app`
```
NAME         STORETYPE     STORE         REFRESH INTERVAL   STATUS         READY   LAST SYNC
app-secret   SecretStore   aws-secrets   1h                 SecretSynced   True    2m28s
```

## `kubectl get application voteball -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status`
```
NAME       SYNC     HEALTH
voteball   Synced   Healthy
```

## `kubectl get pods -n monitoring`
```
NAME                                                        READY   STATUS    RESTARTS   AGE
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0          5m13s
kube-prometheus-stack-grafana-554774fdfb-7vn67              3/3     Running   0          5m24s
kube-prometheus-stack-kube-state-metrics-7db54989c4-z5mfv   1/1     Running   0          5m24s
kube-prometheus-stack-operator-58d9c5976b-rbrkx             1/1     Running   0          5m24s
kube-prometheus-stack-prometheus-node-exporter-2pmjs        1/1     Running   0          5m24s
kube-prometheus-stack-prometheus-node-exporter-b6ncp        1/1     Running   0          5m24s
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          5m12s
```

## `kubectl describe pod backend-5dc97c458d-nls96 -n devops-app` (excerpt)
```
Name:             backend-5dc97c458d-nls96
Namespace:        devops-app
Priority:         0
Service Account:  backend
Node:             ip-10-0-49-247.il-central-1.compute.internal/10.0.49.247
Start Time:       Mon, 20 Jul 2026 13:04:48 +0300
Labels:           app=backend
                  pod-template-hash=5dc97c458d
Annotations:      cloudwatch.aws.amazon.com/auto-annotate-dotnet: true
                  cloudwatch.aws.amazon.com/auto-annotate-java: true
                  cloudwatch.aws.amazon.com/auto-annotate-nodejs: true
                  cloudwatch.aws.amazon.com/auto-annotate-python: true
                  instrumentation.opentelemetry.io/inject-dotnet: true
                  instrumentation.opentelemetry.io/inject-java: true
                  instrumentation.opentelemetry.io/inject-nodejs: true
                  instrumentation.opentelemetry.io/inject-python: true
Status:           Running
IP:               10.0.58.180
IPs:
  IP:           10.0.58.180
Controlled By:  ReplicaSet/backend-5dc97c458d
Init Containers:
  opentelemetry-auto-instrumentation-java:
    Container ID:  containerd://c5229d606cb0747c49e45d7dce5cefe6fe540c2b2c229d47cf39af4e83e637a7
    Image:         066635153087.dkr.ecr.il-central-1.amazonaws.com/eks/observability/adot-autoinstrumentation-java:v2.28.2
    Image ID:      066635153087.dkr.ecr.il-central-1.amazonaws.com/eks/observability/adot-autoinstrumentation-java@sha256:515c8d4156bb800377ecdce87cd7ab5c6645c0d3cb025da60ac4132bce106128
    Port:          <none>
    Host Port:     <none>
    Command:
      cp
      /javaagent.jar
      /otel-auto-instrumentation-java/javaagent.jar
    State:          Terminated
      Reason:       Completed
      Exit Code:    0
      Started:      Mon, 20 Jul 2026 13:04:53 +0300
      Finished:     Mon, 20 Jul 2026 13:04:53 +0300
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     500m
      memory:  64Mi
    Requests:
      cpu:        50m
      memory:     64Mi
    Environment:  <none>
    Mounts:
      /otel-auto-instrumentation-java from opentelemetry-auto-instrumentation-java (rw)
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-lr2b8 (ro)
  opentelemetry-auto-instrumentation-nodejs:
    Container ID:  containerd://d90308faefc444fefed6755f91d4d1102fdb67db87e170772a7de18ae2749c35
    Image:         066635153087.dkr.ecr.il-central-1.amazonaws.com/eks/observability/adot-autoinstrumentation-node:v0.12.0
    Image ID:      066635153087.dkr.ecr.il-central-1.amazonaws.com/eks/observability/adot-autoinstrumentation-node@sha256:d28ba22730cbc406be6cce0455a1a48226fdd6ed174dac40b75c9ef15e82cc21
    Port:          <none>
    Host Port:     <none>
    Command:
      cp
      -r
      /autoinstrumentation/.
      /otel-auto-instrumentation-nodejs
```

## `kubectl logs backend-5dc97c458d-nls96 -n devops-app` (last 15 lines)
```
AwsEksResourceDetector failed: HTTP Error 403: Forbidden
[2026-07-20 10:05:27 +0000] [1] [INFO] Starting gunicorn 23.0.0
[2026-07-20 10:05:27 +0000] [1] [INFO] Listening at: http://0.0.0.0:5000 (1)
[2026-07-20 10:05:27 +0000] [1] [INFO] Using worker: sync
[2026-07-20 10:05:27 +0000] [22] [INFO] Booting worker with pid: 22
[2026-07-20 10:05:27 +0000] [27] [INFO] Booting worker with pid: 27
```
## Additions captured 2026-07-21 (post WAF / alerting / migration-Job pass)

_The sections above are from the 2026-07-20 build. The cluster was rebuilt on 2026-07-21; these
are the parts that did not exist before._

### WAF is attached to the ALB (`aws wafv2 get-web-acl-for-resource`)
```
voteball-alb	bf57cc07-6897-4896-b8fe-877a5db049d0
```

### Rate limit enforced, and scoped to the vote endpoint only
```
# 300-request burst against /api/vote from one address:
    300 x HTTP 403
# ...while, from that same blocked address:
    /            -> 200
    /api/options -> 200
    /api/results -> 200
```

### RDS point-in-time recovery
```
-----------------------------------------------------------------
|                      DescribeDBInstances                      |
+----------------------+----------------+----------+------------+
|  BackupRetentionDays | BackupWindow   | MultiAZ  |  Status    |
+----------------------+----------------+----------+------------+
|  7                   |  01:00-01:30   |  False   |  available |
+----------------------+----------------+----------+------------+
```

### Alert rules loaded by Prometheus (not merely created)
```
voteball-alerts   98m

voteball rule groups: 3, rules: 7 - all state=inactive (healthy)
  VoteballPodCrashLooping / VoteballDeploymentDegraded / VoteballNoBackendAvailable
  VoteballMigrationJobFailed / VoteballBackupJobFailed / VoteballBackupMissing
  VoteballContainerOOMKilled
```

### Alertmanager -> SNS via IRSA (no SMTP on the cluster)
```
serviceaccount annotation: arn:aws:iam::590183895228:role/voteball-alertmanager-irsa
delivery verified end-to-end: NumberOfMessagesPublished=1, NumberOfNotificationsDelivered=1,
NumberOfNotificationsFailed=0 (test alert received by email)
```

### Schema migration runs once per release, before the app rolls
```
# pre-upgrade hook, observed on a real upgrade:
pod/voteball-migrate-2hqww   Scheduled -> Started -> Completed
job/voteball-migrate         Job completed
```

---

## 2026-07-27 — pre-teardown capture

_Captured from the cluster built on 2026-07-22 (nodes aged 4d22h), immediately before a deliberate
`destroy.sh` → `deploy.sh` cycle. Frozen like every section above it — the pod names, ALB hostname and
certificate below stop resolving the moment that cycle runs._

### `kubectl get nodes`
```
NAME                                           STATUS   ROLES    AGE     VERSION
ip-10-0-44-224.il-central-1.compute.internal   Ready    <none>   4d22h   v1.34.9-eks-8f14419
ip-10-0-62-133.il-central-1.compute.internal   Ready    <none>   4d22h   v1.34.9-eks-8f14419
```

### `kubectl get namespaces`
```
NAME                STATUS   AGE
amazon-cloudwatch   Active   4d22h
argocd              Active   4d22h
default             Active   4d22h
devops-app          Active   4d22h
external-secrets    Active   4d22h
kube-node-lease     Active   4d22h
kube-public         Active   4d22h
kube-system         Active   4d22h
monitoring          Active   4d22h
```

### `kubectl get pods -n devops-app`
```
NAME                             READY   STATUS      RESTARTS   AGE
backend-6c9c6d4d7f-nbrfs         1/1     Running     0          9h
backend-6c9c6d4d7f-ngrnl         1/1     Running     0          9h
frontend-7dc9588999-nwq98        1/1     Running     0          9h
frontend-7dc9588999-vqf2n        1/1     Running     0          9h
voteball-backup-29749080-zvpwk   0/1     Completed   0          2d3h
voteball-backup-29750520-9hsgv   0/1     Completed   0          27h
voteball-backup-29751960-jzcdp   0/1     Completed   0          3h43m
worker-5595dcd764-cwcpd          1/1     Running     0          9h
```

### `kubectl get deployments -n devops-app`
```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
backend    2/2     2            2           4d22h
frontend   2/2     2            2           4d22h
worker     1/1     1            1           4d22h
```

### `kubectl get services -n devops-app`
```
NAME       TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
backend    ClusterIP   172.20.149.143   <none>        5000/TCP   4d22h
frontend   ClusterIP   172.20.170.39    <none>        80/TCP     4d22h
```
Both ClusterIP — neither Service is reachable from outside; only the ALB, via the Ingress, reaches in.

### `kubectl get ingress -n devops-app`
```
NAME       CLASS   HOSTS                  ADDRESS                                                                      PORTS   AGE
voteball   alb     voteball.latnook.com   k8s-devopsap-voteball-6fb18c0744-1149291850.il-central-1.elb.amazonaws.com   80      4d22h
```

### `kubectl describe pod backend-6c9c6d4d7f-nbrfs -n devops-app` (app container)
```
Containers:
  backend:
    Image:          590183895228.dkr.ecr.il-central-1.amazonaws.com/voteball-backend:548241e
    Image ID:       ...voteball-backend@sha256:4c39b94cb11a0bffa0178476c657f34c59e93deff9f23dfe6c5f05b635df0f0d
    Port:           5000/TCP
    State:          Running
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     250m
      memory:  256Mi
    Requests:
      cpu:      50m
      memory:   128Mi
    Liveness:   tcp-socket :5000 delay=10s timeout=1s period=20s #success=1 #failure=3
    Readiness:  http-get http://:5000/health delay=5s timeout=1s period=10s #success=1 #failure=3
    Environment Variables from:
      app-config  ConfigMap  Optional: false
      app-secret  Secret     Optional: false
```
Four mandated properties in one block: an immutable git-SHA image tag (never `latest`), resource
requests **and** limits, both liveness and readiness probes, and configuration split across a
ConfigMap (non-secret) and a Secret.

### `kubectl logs backend-6c9c6d4d7f-nbrfs -n devops-app`
```
[2026-07-26 19:54:33 +0000] [1] [INFO] Starting gunicorn 23.0.0
[2026-07-26 19:54:34 +0000] [1] [INFO] Listening at: http://0.0.0.0:5000 (1)
[2026-07-26 19:54:34 +0000] [1] [INFO] Using worker: sync
[2026-07-26 19:54:34 +0000] [22] [INFO] Booting worker with pid: 22
[2026-07-26 19:54:34 +0000] [27] [INFO] Booting worker with pid: 27
```

## Demos — 2026-07-27 pre-teardown

### 1. HTTPS with a valid ACM certificate, HTTP redirected
```
$ curl -sI https://voteball.latnook.com | head -1
HTTP/2 200

$ openssl s_client -connect voteball.latnook.com:443 | openssl x509 -noout -issuer -subject -dates
issuer=C=US, O=Amazon, CN=Amazon RSA 2048 M04
subject=CN=voteball.latnook.com
notBefore=Jul 22 00:00:00 2026 GMT
notAfter=Feb  4 23:59:59 2027 GMT

$ curl -sI http://voteball.latnook.com | head -2
HTTP/1.1 301 Moved Permanently
Server: awselb/2.0
```

### 2 & 3. frontend → backend → RDS
```
$ curl -sf https://voteball.latnook.com/api/options | head -c 200
{"clubs":[{"domestic_league_id":null,"id":2858,"league_id":6,"logo_url":"https://upload.wikimedia.org/...","name_en":"1. FC Köln",...

$ curl -sf "https://voteball.latnook.com/api/results?by=all"
{"previous":[{"count":2,"party_id":10},{"count":1,"party_id":5},{"count":1,"party_id":4},{"count":1,"party_id":14}],
 "upcoming":[{"count":3,"party_id":4},{"count":1,"party_id":11},{"count":1,"party_id":3}]}
```
A single unauthenticated request traverses ALB → Ingress → frontend Service → nginx → backend Service
→ Flask → RDS and returns seeded data. **5 votes** — the figure the post-rebuild section must match.

### 4. S3 and SNS via IRSA
```
$ kubectl create job --from=cronjob/voteball-backup evidence-backup -n devops-app
job.batch/evidence-backup created
$ kubectl wait --for=condition=complete job/evidence-backup -n devops-app --timeout=240s
job.batch/evidence-backup condition met
$ aws s3 ls s3://voteball-rollups-590183895228/backups/ | tail -2
2026-07-27 05:00:06      12578 voteball-2026-07-27T02-00-04Z.sql.gz   <- nightly CronJob
2026-07-27 08:44:28      12578 voteball-2026-07-27T05-44-26Z.sql.gz   <- this on-demand run
```

ServiceAccount roles — only `worker` and `backup` carry AWS credentials:
```
NAME       ROLE
backend    <none>
backup     arn:aws:iam::590183895228:role/voteball-backup-irsa
default    <none>
frontend   <none>
worker     arn:aws:iam::590183895228:role/voteball-worker-irsa
```

SNS is a live delivery path, not a configured black hole (7-day totals):
```
subscription:                    email  ...:voteball-notifications:2f8a64b3-...  (Confirmed)
NumberOfMessagesPublished        42.0
NumberOfNotificationsDelivered   45.0
NumberOfNotificationsFailed      0.0
alertmanager SA -> arn:aws:iam::590183895228:role/voteball-alertmanager-irsa
```

### 5. NetworkPolicy isolation — with a control
```
$ kubectl get networkpolicy -n devops-app
allow-alb-to-frontend       app=frontend
allow-app-egress            app in (backend,backup,frontend,migrate,worker)
allow-dns-egress            <none>
allow-frontend-to-backend   app=backend
default-deny                <none>

$ # worker -> backend:5000 (must NOT connect)
BLOCKED by NetworkPolicy: TimeoutError

$ # control: worker -> RDS:5432 (must connect)
REACHABLE (expected — worker needs RDS)
```

> **The control matters.** The probe previously documented in `README.submission.md`
> (`wget ... || echo BLOCKED`) printed `BLOCKED` because **`wget` is not installed in the worker
> image** — it would have reported success with the NetworkPolicy deleted entirely. The pair above
> uses a Python socket connect and proves both directions: the denied path times out, the permitted
> path connects.

### 6. Pod restart while the site stays up
```
$ kubectl delete pod frontend-7dc9588999-nwq98 -n devops-app
pod "frontend-7dc9588999-nwq98" deleted from devops-app namespace

  frontend-7dc9588999-4sxjz   0/1   Running    <- replacement, readiness pending
  frontend-7dc9588999-vqf2n   1/1   Running    <- survivor keeps serving
  ...
  frontend-7dc9588999-4sxjz   1/1   Running   102s
  frontend-7dc9588999-vqf2n   1/1   Running   9h

HTTP status codes observed, continuous polling across the delete and the full
replacement cycle through to Ready:
   1050 200
   non-200: 0
```
1,050 consecutive HTTP 200s spanning the deletion and the replacement reaching `1/1 Ready`. Two
replicas plus a PodDisruptionBudget mean losing one is invisible to users.

---

## 2026-07-27 — post-rebuild capture

_Captured from a cluster built by `./scripts/deploy.sh` immediately after `./scripts/destroy.sh`,
restoring RDS from the final snapshot that teardown produced. This section and the pre-teardown one
above are the two halves of one destroy/rebuild cycle: **the vote count is identical across it.**_

### Lifecycle summary

```
destroy.sh   6 ordered steps          Destroy complete! Resources: 112 destroyed.   exit 0
             final snapshot           voteball-eks-db-final-20260722065933
                                      created 2026-07-27T06:13:54Z  (NOT 07-22 -- the identifier
                                      embeds time_static.deploy, so verify by SnapshotCreateTime)
deploy.sh    8 ordered steps          Apply complete! Resources: 112 added, 0 changed, 0 destroyed.
             restored from            voteball-eks-db-final-20260722065933
                                      exit 0

votes before: 5      votes after: 5      (party 10 x2, 5, 4, 14 -- identical distribution)
```

### `kubectl get nodes`
```
NAME                                          STATUS   ROLES    AGE   VERSION
ip-10-0-40-9.il-central-1.compute.internal    Ready    <none>   11m   v1.34.9-eks-bca9cf6
ip-10-0-54-67.il-central-1.compute.internal   Ready    <none>   11m   v1.34.9-eks-bca9cf6
```

### `kubectl get namespaces`
```
NAME                STATUS   AGE
amazon-cloudwatch   Active   10m
argocd              Active   12m
default             Active   16m
devops-app          Active   8m3s
external-secrets    Active   13m
kube-node-lease     Active   16m
kube-public         Active   16m
kube-system         Active   16m
monitoring          Active   10m
```

### `kubectl get pods -n devops-app`
```
NAME                        READY   STATUS      RESTARTS   AGE
backend-6945f9f7d8-cht9d    1/1     Running     0          8m3s
backend-6945f9f7d8-d9njl    1/1     Running     0          8m3s
evidence-backup-smc6m       0/1     Completed   0          2m29s
frontend-65bd4d9fcb-bhh5d   1/1     Running     0          105s
frontend-65bd4d9fcb-svrfz   1/1     Running     0          8m3s
worker-7855fc557c-2rfgm     1/1     Running     0          8m4s
```

### `kubectl get deployments -n devops-app`
```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
backend    2/2     2            2           8m4s
frontend   2/2     2            2           8m4s
worker     1/1     1            1           8m4s
```

### `kubectl get services -n devops-app`
```
NAME       TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
backend    ClusterIP   172.20.173.163   <none>        5000/TCP   8m4s
frontend   ClusterIP   172.20.23.51     <none>        80/TCP     8m4s
```

### `kubectl get ingress -n devops-app`
```
NAME       CLASS   HOSTS                  ADDRESS                                                                     PORTS   AGE
voteball   alb     voteball.latnook.com   k8s-devopsap-voteball-6fb18c0744-433102010.il-central-1.elb.amazonaws.com   80      8m4s
```

### `kubectl describe pod backend-6945f9f7d8-cht9d -n devops-app` (app container)
```
  backend:
    Image:          590183895228.dkr.ecr.il-central-1.amazonaws.com/voteball-backend:0275cc6
    Port:           5000/TCP
    State:          Running
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     250m
      memory:  256Mi
    Requests:
      cpu:      50m
      memory:   128Mi
    Liveness:   tcp-socket :5000 delay=10s timeout=1s period=20s #success=1 #failure=3
    Readiness:  http-get http://:5000/health delay=5s timeout=1s period=10s #success=1 #failure=3
    Environment Variables from:
      app-config  ConfigMap  Optional: false
      app-secret  Secret     Optional: false
```

### `kubectl logs` — see `evidence/2026-07-27-post-rebuild-kubectl.txt`

### ArgoCD owns the release
```
NAME       SYNC     HEALTH    REVISION
voteball   Synced   Healthy   ea9feebad75b88ffb9eee06a5af9030aaa5c8ad4
```
`ea9feeb` is the `Deploy: sync values.yaml from Terraform outputs` commit that `deploy.sh` step 6
pushed. The cluster and `master` agree — GitOps has taken over from the bootstrap install.

## Demos — 2026-07-27 post-rebuild

### 1. HTTPS with a newly issued ACM certificate
```
HTTP/2 200
issuer=C=US, O=Amazon, CN=Amazon RSA 2048 M01
subject=CN=voteball.latnook.com
notBefore=Jul 27 00:00:00 2026 GMT
notAfter=Feb  9 23:59:59 2027 GMT

$ curl -sI http://voteball.latnook.com | head -2
HTTP/1.1 301 Moved Permanently
Server: awselb/2.0
```
Pre-teardown the certificate was `Amazon RSA 2048 M04`, `notBefore Jul 22`. A different issuer and a
`notBefore` of today is independent proof the stack was genuinely rebuilt rather than left running.

### 2 & 3. frontend → backend → RDS, with votes restored
```
$ curl -sf https://voteball.latnook.com/api/options | head -c 180
{"clubs":[{"domestic_league_id":null,"id":2858,"league_id":6,"logo_url":"https://upload.wikimedia.org/...","name_en":"1. FC Köln",...

$ curl -sf "https://voteball.latnook.com/api/results?by=all"
{"previous":[{"count":2,"party_id":10},{"count":1,"party_id":5},{"count":1,"party_id":4},{"count":1,"party_id":14}],
 "upcoming":[{"count":3,"party_id":4},{"count":1,"party_id":11},{"count":1,"party_id":3}]}
```
Byte-identical to the pre-teardown section. **The snapshot restore preserved every vote.**

### 4. S3 and SNS via IRSA — on a bucket that did not exist ten minutes earlier
```
-- objects before: (empty -- the rollups bucket is created fresh each cycle, force_destroy = true)
$ kubectl create job --from=cronjob/voteball-backup evidence-backup -n devops-app
job.batch/evidence-backup condition met
-- objects after:
2026-07-27 09:37:31      12579 voteball-2026-07-27T06-37-29Z.sql.gz

NAME       ROLE
backend    <none>
backup     arn:aws:iam::590183895228:role/voteball-backup-irsa
default    <none>
frontend   <none>
worker     arn:aws:iam::590183895228:role/voteball-worker-irsa
```

SNS, verified end to end after the topic was destroyed and recreated:
```
subscription PendingConfirmation: false        (re-confirmed by the operator after the rebuild)
NumberOfNotificationsDelivered:   1.0
NumberOfNotificationsFailed:      0.0
```

### 5. NetworkPolicy isolation, with a control
```
allow-alb-to-frontend       app=frontend
allow-app-egress            app
allow-dns-egress            <none>
allow-frontend-to-backend   app=backend
default-deny                <none>

worker -> backend:5000   BLOCKED by NetworkPolicy: TimeoutError
worker -> RDS:5432       RDS REACHABLE (probe works)
```

### 6. Pod restart while the site stays up
```
$ kubectl delete pod frontend-65bd4d9fcb-nrbtk -n devops-app
pod "frontend-65bd4d9fcb-nrbtk" deleted
pod/frontend-65bd4d9fcb-bhh5d condition met

   700 200
   probes: 700   non-200: 0
   window: 09:38:03 -> 09:38:56
```

## Known behaviour of this cycle: DNS negative caching

For a few minutes after the rebuild the site was unreachable through some public resolvers while
being perfectly healthy. Sequence: teardown removed the Route53 record → resolvers queried during the
gap and cached the "no address" answer → external-dns recreated the record as an **ALIAS to an ALB
still in `provisioning`**, which resolves to nothing until the ALB is `active`.

Negative caching is bounded by RFC 2308 at `min(SOA MINIMUM, SOA record TTL)` = `min(86400, 900)` =
**15 minutes**, so it self-heals. Observed: `8.8.8.8`, `9.9.9.9` and `208.67.222.222` all serving the
correct address while `1.1.1.1` still held the negative answer.

**Diagnosing it:** compare an authoritative query against a public resolver. If the authoritative
nameserver answers and a public resolver does not, it is cache, not configuration —
```bash
dig +short @ns-2035.awsdns-62.co.uk voteball.latnook.com A   # authoritative truth
aws elbv2 describe-load-balancers --query 'LoadBalancers[].State.Code'   # must be "active"
```
An `ANSWER: 0` with `status: NOERROR` (rather than `NXDOMAIN`) is the signature: the name exists, the
alias target just has no address yet.
