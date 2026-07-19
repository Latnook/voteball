# Live cluster snapshot (evidence for README.submission.md)

_Captured 2026-07-19 from the running EKS cluster before teardown._

## `kubectl get nodes`
```
NAME                                           STATUS   ROLES    AGE    VERSION
ip-10-0-32-100.il-central-1.compute.internal   Ready    <none>   164m   v1.34.9-eks-8f14419
ip-10-0-62-195.il-central-1.compute.internal   Ready    <none>   164m   v1.34.9-eks-8f14419
```

## `kubectl get namespaces`
```
NAME                STATUS   AGE
amazon-cloudwatch   Active   141m
argocd              Active   36m
default             Active   168m
devops-app          Active   106m
external-secrets    Active   142m
kube-node-lease     Active   168m
kube-public         Active   168m
kube-system         Active   168m
monitoring          Active   38m
```

## `kubectl get pods -n devops-app`
```
NAME                        READY   STATUS    RESTARTS   AGE
backend-5c784d7c87-l4bnj    1/1     Running   0          4m37s
backend-5c784d7c87-q5wtl    1/1     Running   0          4m
frontend-859cdbcbd5-fj9tr   1/1     Running   0          4m37s
frontend-859cdbcbd5-vfdm4   1/1     Running   0          4m9s
worker-5d959f8f6b-g2czr     1/1     Running   0          4m37s
```

## `kubectl get deployments -n devops-app`
```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
backend    2/2     2            2           101m
frontend   2/2     2            2           101m
worker     1/1     1            1           101m
```

## `kubectl get services -n devops-app`
```
NAME       TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
backend    ClusterIP   172.20.24.118    <none>        5000/TCP   101m
frontend   ClusterIP   172.20.185.185   <none>        80/TCP     101m
```

## `kubectl get ingress -n devops-app`
```
NAME       CLASS   HOSTS                  ADDRESS                                                                     PORTS   AGE
voteball   alb     voteball.latnook.com   k8s-devopsap-voteball-6fb18c0744-331227380.il-central-1.elb.amazonaws.com   80      81m
```

## `kubectl get hpa,pdb,cronjob,networkpolicy -n devops-app`
```
NAME                                          REFERENCE            TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/backend   Deployment/backend   cpu: 6%/70%   2         5         2          81m

NAME                                  MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/backend    1               N/A               1                     81m
poddisruptionbudget.policy/frontend   1               N/A               1                     81m

NAME                            SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
cronjob.batch/voteball-backup   0 2 * * *   <none>     False     0        <none>          81m

NAME                                                        POD-SELECTOR                              AGE
networkpolicy.networking.k8s.io/allow-alb-to-frontend       app=frontend                              81m
networkpolicy.networking.k8s.io/allow-app-egress            app in (backend,backup,frontend,worker)   81m
networkpolicy.networking.k8s.io/allow-dns-egress            <none>                                    81m
networkpolicy.networking.k8s.io/allow-frontend-to-backend   app=backend                               81m
networkpolicy.networking.k8s.io/default-deny                <none>                                    81m
```

## `kubectl get serviceaccounts -n devops-app -o custom-columns=NAME:.metadata.name,IRSA-ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn`
```
NAME       IRSA-ROLE
backend    <none>
backup     <none>
default    <none>
frontend   <none>
worker     <none>
```

## `kubectl get externalsecret -n devops-app`
```
NAME         STORETYPE     STORE         REFRESH INTERVAL   STATUS         READY   LAST SYNC
app-secret   SecretStore   aws-secrets   1h                 SecretSynced   True    34m
```

## `kubectl get application voteball -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status`
```
NAME       SYNC     HEALTH
voteball   Synced   Healthy
```

## `kubectl get pods -n monitoring`
```
NAME                                                        READY   STATUS    RESTARTS   AGE
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0          38m
kube-prometheus-stack-grafana-8679649b9f-v58nh              3/3     Running   0          30m
kube-prometheus-stack-kube-state-metrics-7db54989c4-rjfjv   1/1     Running   0          38m
kube-prometheus-stack-operator-58d9c5976b-7xnw2             1/1     Running   0          38m
kube-prometheus-stack-prometheus-node-exporter-5hjt5        1/1     Running   0          38m
kube-prometheus-stack-prometheus-node-exporter-xgzdr        1/1     Running   0          38m
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          38m
```

## `kubectl describe pod backend-5c784d7c87-l4bnj -n devops-app` (excerpt)
```
Name:             backend-5c784d7c87-l4bnj
Namespace:        devops-app
Priority:         0
Service Account:  backend
Node:             ip-10-0-62-195.il-central-1.compute.internal/10.0.62.195
Start Time:       Sun, 19 Jul 2026 21:31:52 +0300
Labels:           app=backend
                  pod-template-hash=5c784d7c87
Annotations:      cloudwatch.aws.amazon.com/auto-annotate-dotnet: true
                  cloudwatch.aws.amazon.com/auto-annotate-java: true
                  cloudwatch.aws.amazon.com/auto-annotate-nodejs: true
                  cloudwatch.aws.amazon.com/auto-annotate-python: true
                  instrumentation.opentelemetry.io/inject-dotnet: true
                  instrumentation.opentelemetry.io/inject-java: true
                  instrumentation.opentelemetry.io/inject-nodejs: true
                  instrumentation.opentelemetry.io/inject-python: true
Status:           Running
IP:               10.0.56.110
IPs:
  IP:           10.0.56.110
Controlled By:  ReplicaSet/backend-5c784d7c87
Init Containers:
  opentelemetry-auto-instrumentation-java:
    Container ID:  containerd://ac5f5cc653b0a600d742f256df6237d67b86cf8c96f9238a593914c5b7866641
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
      Started:      Sun, 19 Jul 2026 21:31:55 +0300
      Finished:     Sun, 19 Jul 2026 21:31:55 +0300
    Ready:          True
    Restart Count:  0
    Limits:
```

## `kubectl logs backend-5c784d7c87-l4bnj -n devops-app` (last 15 lines)
```
AwsEksResourceDetector failed: HTTP Error 403: Forbidden
[2026-07-19 18:32:19 +0000] [1] [INFO] Starting gunicorn 23.0.0
[2026-07-19 18:32:19 +0000] [1] [INFO] Listening at: http://0.0.0.0:5000 (1)
[2026-07-19 18:32:19 +0000] [1] [INFO] Using worker: sync
[2026-07-19 18:32:19 +0000] [21] [INFO] Booting worker with pid: 21
[2026-07-19 18:32:19 +0000] [26] [INFO] Booting worker with pid: 26
```
