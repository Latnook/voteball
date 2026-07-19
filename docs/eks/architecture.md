# Architecture

Voteball on EKS. Solid arrows = request/data flow; the AWS services on the right are reached from the
cluster. Only the frontend is internet-facing; backend/worker/DB are private.

```mermaid
flowchart LR
    user([User<br/>browser])

    subgraph AWS["AWS — il-central-1 · VPC 10.0.0.0/16"]
      dns[Route53<br/>voteball.latnook.com]
      acm[ACM cert]

      subgraph PUB["Public subnets (2 AZs)"]
        alb[ALB<br/>HTTPS 443 · TLS via ACM]
        nat[NAT GW]
      end

      subgraph PRIV["Private subnets (2 AZs) — EKS nodes/pods"]
        subgraph NS["namespace: devops-app"]
          fe[Deployment: frontend<br/>nginx :8080 ·x2·]
          be[Deployment: backend<br/>Flask/gunicorn :5000 ·x2·]
          wk[Deployment: worker<br/>rollup poller ·x1·]
          cron[[CronJob: backup<br/>nightly pg_dump]]
          cfg[(ConfigMap<br/>app-config)]
          sec[(Secret app-secret<br/>via ExternalSecret)]
          sa["ServiceAccounts<br/>worker+backup = IRSA<br/>frontend+backend = none"]
        end
        addons["Platform add-ons (kube-system/argocd/monitoring):<br/>ALB Controller · ESO · Cluster Autoscaler · NTH<br/>CloudWatch · metrics-server · external-dns · ArgoCD · Prometheus/Grafana"]
      end

      subgraph DBSUB["DB subnets (isolated, no NAT/IGW)"]
        rds[(RDS Postgres<br/>private · SG=node-SG only · sslmode=require · encrypted)]
      end

      sm[Secrets Manager<br/>voteball/app-secret]
      s3[(S3 rollups bucket<br/>snapshots/ + backups/)]
      sns[SNS<br/>milestone alerts]
      ecr[ECR<br/>4 image repos]
      cw[CloudWatch<br/>logs + metrics]
    end

    gh[GitHub Actions<br/>OIDC → build/Trivy/ECR] --> ecr
    gh -. tag bump .-> argocdsync[ArgoCD watches repo] -. syncs .-> NS

    user -->|HTTPS| dns --> alb
    acm -. cert .- alb
    alb -->|/*| fe -->|/api/*| be --> rds
    wk --> rds
    wk -->|IRSA| sns
    wk -->|IRSA PutObject snapshots/| s3
    cron -->|IRSA PutObject backups/| s3
    be -. envFrom .- cfg
    be -. envFrom .- sec
    sec <-->|ESO sync| sm
    fe & be & wk -. pull image .- ecr
    NS -. logs/metrics .-> cw
```

## Zones & exposure
- **Internet-facing:** only the ALB (public subnets) → frontend. HTTP is redirected to HTTPS.
- **Private:** all pods + RDS are in private/DB subnets. Backend/worker/DB have no public entry;
  NetworkPolicies further restrict pod-to-pod (backend reachable only from frontend).
- **Egress:** pods reach AWS APIs (SNS/S3/Secrets Manager) and pull nothing untrusted; RDS is reached
  directly in-VPC.

## What builds what
- **Terraform (`terraform-eks/`):** the VPC, EKS cluster + node group, RDS, ECR, ACM, S3, SNS, Secrets
  Manager (container only), IRSA roles, and every platform add-on.
- **Helm chart (`charts/voteball`), delivered by ArgoCD:** everything in the `devops-app` box.
- **GitHub Actions:** builds/scans/pushes images and bumps the chart's image tag; ArgoCD syncs it.
