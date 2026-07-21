# Live cluster snapshot (evidence for README.submission.md)

_Captured 2026-07-20 from the running EKS cluster._
_Sections below the "Additions captured 2026-07-21" heading are from the current build; everything above
it was captured from the 2026-07-20 build and is kept as the original evidence._

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
