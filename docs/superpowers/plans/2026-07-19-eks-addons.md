# EKS Platform Add-ons Implementation Plan — Plan 2b

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the six platform add-ons the app deployment (Plan 3) and the cluster's reliability/observability story depend on — AWS Load Balancer Controller, External Secrets Operator, Cluster Autoscaler, AWS Node Termination Handler, CloudWatch Container Insights, and metrics-server — into the live `terraform` cluster, each with a scoped IRSA role where it needs one.

**Architecture:** Extends the **same `terraform/` stack** (the cluster is already live from Plan 2). Adds the `helm` + `kubernetes` providers authenticated to the cluster via `aws eks get-token` exec auth, then installs add-ons as `helm_release` resources (plus one `aws_eks_addon` for CloudWatch). Add-on **controller** IRSA roles use the community `terraform-aws-modules/iam//modules/iam-role-for-service-accounts-eks` helper with its pre-vetted, AWS-authored policies (the app's worker/backup IRSA stays hand-rolled — that's the graded security centerpiece; controller roles are matched to AWS's own published policies via the helper).

**Tech Stack:** Terraform ≥ 1.5, `hashicorp/aws ~> 5.0`, `hashicorp/helm ~> 2.17`, `hashicorp/kubernetes ~> 2.31`, `terraform-aws-modules/iam/aws ~> 5.0`, live EKS cluster `voteball` (K8s 1.34), region `il-central-1`, account `590183895228`.

## Global Constraints

- Extends the existing `terraform/` stack (Plan 2). Run all `terraform` from `terraform/` in the main working tree, never a worktree.
- **App namespace is `devops-app`** (created later by the Plan 3 chart). Add-ons live in their own namespaces: `kube-system` (ALB controller, Cluster Autoscaler, NTH, metrics-server), `external-secrets` (ESO), `amazon-cloudwatch` (CloudWatch agent).
- **IRSA split:** add-on controller roles = community helper (pre-vetted AWS policies); the app's `worker`/`backup` roles stay hand-rolled (Plan 2, `irsa.tf`). No workload gets cluster-admin.
- **Pin chart versions** for reproducibility, but **verify each against K8s 1.34 at build time** with `helm search repo <chart> --versions` (chart versions drift; the pins below are starting points to confirm/bump — treated like the EKS-version check in Plan 2, an environment check, not a placeholder).
- **Destroy ordering caveat:** the `helm`/`kubernetes` providers authenticate from `module.eks` outputs, so `helm_release` resources must be destroyed *before* the cluster. Terraform's dependency graph handles this automatically (releases depend on the providers, which depend on the cluster) — but never `-target` the cluster for destroy without the releases, or the providers lose their endpoint mid-destroy.
- **Cost:** these add-ons run as pods on the **already-billing** Plan 2 nodes, so marginal cost is small (a few controller pods + CloudWatch log ingest ~$3–8/mo). No new always-on infra until Plan 3 creates the ALB.
- **Commit and push to `master` as each task completes.** Plain imperative messages. Never force-push.

**Pre-flight:** the Plan 2 cluster must be live — `kubectl get nodes` shows 2 Ready. `terraform/` already `init`-ed.

---

### Task 1: Wire up the helm + kubernetes providers

Add the two providers, authenticated to the live cluster via exec auth, plus their version pins.

**Files:**
- Modify: `terraform/versions.tf` (add helm + kubernetes required_providers)
- Create: `terraform/providers-k8s.tf`

**Interfaces:**
- Consumes: `module.eks.cluster_name`, `module.eks.cluster_endpoint`, `module.eks.cluster_certificate_authority_data`.
- Produces: configured `helm` + `kubernetes` providers used by every later task.

- [ ] **Step 1: Add provider pins to `terraform/versions.tf`**

Add inside `required_providers` (after the `aws` block):

```hcl
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17" # 2.x keeps the nested `kubernetes {}` block used below (v3 changed syntax)
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
```

- [ ] **Step 2: Create `terraform/providers-k8s.tf`**

```hcl
# Authenticate the helm + kubernetes providers to the live cluster using short-lived exec tokens
# (aws eks get-token) -- no long-lived kubeconfig in state. These providers can only initialize once
# the cluster exists (Plan 2), which is why add-ons are a separate plan applied after it.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

locals {
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = local.eks_exec.api_version
      command     = local.eks_exec.command
      args        = local.eks_exec.args
    }
  }
}
```

- [ ] **Step 3: Init + validate**

Run: `cd terraform && terraform init -input=false && terraform validate`
Expected: helm + kubernetes providers installed; `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add terraform/versions.tf terraform/providers-k8s.tf terraform/.terraform.lock.hcl
git commit -m "Add helm + kubernetes providers (exec auth to the EKS cluster)"
git push
```

---

### Task 2: No-IRSA add-ons — metrics-server + Node Termination Handler

The two add-ons that need no AWS permissions. metrics-server feeds the HPA; NTH (IMDS mode) gracefully drains a Spot node on reclamation using only in-cluster RBAC.

**Files:**
- Create: `terraform/addons-basic.tf`

**Interfaces:**
- Consumes: the `helm` provider (Task 1).
- Produces: `helm_release.metrics_server`, `helm_release.node_termination_handler`.

- [ ] **Step 1: Verify chart versions for K8s 1.34**

Run:
```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null; \
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null; helm repo update >/dev/null
helm search repo metrics-server/metrics-server --versions | head -3
helm search repo eks/aws-node-termination-handler --versions | head -3
```
Expected: note the latest chart versions; use them (or confirm the pins below) in Step 2.

- [ ] **Step 2: Create `terraform/addons-basic.tf`**

```hcl
# metrics-server: supplies CPU/memory metrics to the Kubernetes metrics API, which the app's HPA
# (Plan 3) reads. No AWS permissions -- pure in-cluster.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.13.1" # verified for K8s 1.34 via `helm search repo` on 2026-07-19
  namespace  = "kube-system"
}

# AWS Node Termination Handler (IMDS mode): watches the node's own instance metadata for the 2-minute
# Spot interruption notice and cordons+drains the node so pods reschedule cleanly instead of being
# hard-killed. IMDS mode needs only in-cluster RBAC (cordon/drain) -- no IRSA, no AWS API calls.
resource "helm_release" "node_termination_handler" {
  name       = "aws-node-termination-handler"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
  version    = "0.21.0" # verified latest via `helm search repo` on 2026-07-19 (app v1.19.0)
  namespace  = "kube-system"

  set {
    name  = "enableSpotInterruptionDraining"
    value = "true"
  }
}
```

- [ ] **Step 3: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add terraform/addons-basic.tf
git commit -m "Add metrics-server + Node Termination Handler (no-IRSA add-ons)"
git push
```

---

### Task 3: AWS Load Balancer Controller (IRSA + release)

The controller that turns a Kubernetes Ingress into a real ALB (Plan 3 needs this). IRSA role from the community helper with AWS's official LB-controller policy.

**Files:**
- Create: `terraform/addon-alb.tf`

**Interfaces:**
- Consumes: `module.eks.oidc_provider_arn`, `module.vpc.vpc_id`, the `helm` provider.
- Produces: `module.alb_irsa.iam_role_arn`, `helm_release.aws_load_balancer_controller`.

- [ ] **Step 1: Create `terraform/addon-alb.tf`**

```hcl
# IRSA role for the ALB controller. The community helper attaches AWS's OWN published
# load-balancer-controller policy (attach_load_balancer_controller_policy) -- the authoritative
# least-privilege definition for this controller, tracked across controller versions.
module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-alb-controller-irsa"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.2" # verified latest via `helm search repo` on 2026-07-19 (app v3.4.2)
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  # Let the chart create the SA, annotated with the IRSA role ARN.
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_irsa.iam_role_arn
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add terraform/addon-alb.tf
git commit -m "Add AWS Load Balancer Controller (community IRSA + helm release)"
git push
```

---

### Task 4: External Secrets Operator (IRSA + namespace + release)

ESO syncs the Secrets Manager `voteball/app-secret` into a Kubernetes Secret (Plan 3 wires the ExternalSecret). IRSA scoped to *read that one secret*.

**Files:**
- Create: `terraform/addon-eso.tf`

**Interfaces:**
- Consumes: `module.eks.oidc_provider_arn`, `aws_secretsmanager_secret.app.arn` (Plan 2), the `helm` provider.
- Produces: `module.eso_irsa.iam_role_arn`, `helm_release.external_secrets`.

- [ ] **Step 1: Create `terraform/addon-eso.tf`**

```hcl
# IRSA role for ESO, scoped read-only to the ONE app secret (not all of Secrets Manager). The helper's
# external_secrets policy grants secretsmanager:GetSecretValue/DescribeSecret on the given ARNs only.
module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                      = "${var.cluster_name}-eso-irsa"
  attach_external_secrets_policy = true
  # Scope to exactly the app secret ARN (+ its 6-char suffix) -- least privilege.
  external_secrets_secrets_manager_arns = ["${aws_secretsmanager_secret.app.arn}*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.8.0" # verified latest via `helm search repo` on 2026-07-19 (app v2.8.0)
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eso_irsa.iam_role_arn
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add terraform/addon-eso.tf
git commit -m "Add External Secrets Operator (IRSA scoped to app secret + helm release)"
git push
```

---

### Task 5: Cluster Autoscaler (IRSA + release)

Scales the node group 2→4 when pods can't schedule, and back down. IRSA scoped to this cluster's ASG via the helper's cluster-autoscaler policy.

**Files:**
- Create: `terraform/addon-autoscaler.tf`

**Interfaces:**
- Consumes: `module.eks.oidc_provider_arn`, `module.eks.cluster_name`, the `helm` provider.
- Produces: `module.autoscaler_irsa.iam_role_arn`, `helm_release.cluster_autoscaler`.

- [ ] **Step 1: Create `terraform/addon-autoscaler.tf`**

```hcl
# IRSA for Cluster Autoscaler, scoped (via the helper's cluster_autoscaler policy) to autoscaling
# actions on THIS cluster's ASG only -- discovered through the k8s.io/cluster-autoscaler/<name>=owned
# tag set on the node group in Plan 2's eks.tf.
module "autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                        = "${var.cluster_name}-cluster-autoscaler-irsa"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.58.0" # verified latest via `helm search repo` on 2026-07-19 (app v1.35.0)
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.autoscaler_irsa.iam_role_arn
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add terraform/addon-autoscaler.tf
git commit -m "Add Cluster Autoscaler (IRSA scoped to node-group ASG + helm release)"
git push
```

---

### Task 6: CloudWatch Container Insights (IRSA + managed EKS add-on)

Ships pod logs + metrics to CloudWatch via the managed `amazon-cloudwatch-observability` EKS add-on (cleaner than a hand-wired Fluent Bit). IRSA role carries AWS's `CloudWatchAgentServerPolicy`.

**Files:**
- Create: `terraform/addon-cloudwatch.tf`

**Interfaces:**
- Consumes: `module.eks.oidc_provider_arn`, `module.eks.cluster_name`.
- Produces: `module.cloudwatch_irsa.iam_role_arn`, `aws_eks_addon.cloudwatch`.

- [ ] **Step 1: Create `terraform/addon-cloudwatch.tf`**

```hcl
# IRSA for the CloudWatch agent. No pre-baked helper toggle exists for CloudWatch, so attach AWS's
# managed CloudWatchAgentServerPolicy (write-only telemetry: logs:PutLogEvents/CreateLogStream/
# CreateLogGroup + cloudwatch:PutMetricData) via role_policy_arns. The add-on's SA is
# amazon-cloudwatch:cloudwatch-agent.
module "cloudwatch_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-cloudwatch-irsa"
  role_policy_arns = {
    cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
    }
  }
}

# Managed EKS add-on: deploys the CloudWatch agent + Fluent Bit for Container Insights (pod logs +
# performance metrics to CloudWatch). Logging lives outside the cluster (AWS-native, IAM-gated) --
# keeps the node RAM budget lighter than an in-cluster Loki.
resource "aws_eks_addon" "cloudwatch" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  service_account_role_arn = module.cloudwatch_irsa.iam_role_arn

  # If a newer add-on version is required for K8s 1.34, set addon_version (find it via:
  # aws eks describe-addon-versions --addon-name amazon-cloudwatch-observability
  #   --kubernetes-version 1.34 --region il-central-1 --query 'addons[].addonVersions[].addonVersion').
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add terraform/addon-cloudwatch.tf
git commit -m "Add CloudWatch Container Insights (managed add-on + IRSA)"
git push
```

---

### Task 7: Apply all add-ons + verify (STOP for user)

Apply the whole add-on layer against the live cluster and confirm every controller is Running and healthy.

- [ ] **Step 1: Plan + review**

Run: `cd terraform && terraform plan -input=false -var-file=voteball.tfvars -out=tfplan | tail -30`
Expected: plan adds the 6 IRSA-helper roles/policies + 5 helm_release + 1 eks_addon (no destroys). Review the summary.

- [ ] **Step 2: Apply (low marginal cost — pods on existing nodes; stream)**

Run: `cd terraform && terraform apply -input=false tfplan` (background/stream; ~3–5 min — helm releases + add-on rollout).
Expected: `Apply complete!`

- [ ] **Step 3: Verify every controller is Running**

Run:
```bash
kubectl get pods -n kube-system | grep -E "aws-load-balancer|cluster-autoscaler|node-termination|metrics-server"
kubectl get pods -n external-secrets
kubectl get pods -n amazon-cloudwatch
kubectl get sa -n kube-system aws-load-balancer-controller -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}'
kubectl top nodes   # proves metrics-server is serving the metrics API
```
Expected: ALB controller (2 pods), cluster-autoscaler, NTH (2, DaemonSet), metrics-server all Running; ESO pods Running; CloudWatch agent + Fluent Bit Running; the ALB-controller SA carries the IRSA role-arn annotation; `kubectl top nodes` returns numbers.

- [ ] **Step 4: Commit + STOP**

```bash
cd /home/latnook/Documents/Voteball
git add -A terraform/
git commit -m "Apply EKS add-ons; all controllers verified Running"
git push
```

Then report to the user: all six add-ons Running + IRSA annotations confirmed; the cluster is now Plan-3-ready (Ingress→ALB, ExternalSecret, HPA all have their controllers); stack still billing; offer teardown or continue to **Plan 3 (app Helm chart)**.

---

## Self-Review

**1. Spec coverage** (all six add-ons from the design's Plan 2b):
- AWS Load Balancer Controller (IRSA + release) → Task 3. ✅
- External Secrets Operator (IRSA scoped to app secret + release) → Task 4. ✅
- Cluster Autoscaler (IRSA scoped to ASG + release) → Task 5. ✅
- Node Termination Handler (no IRSA, IMDS) → Task 2. ✅
- CloudWatch Container Insights (managed add-on + IRSA) → Task 6. ✅
- metrics-server (no IRSA) → Task 2. ✅
- Providers (helm/kubernetes exec auth) → Task 1. ✅
- Apply + verify → Task 7. ✅

**2. Placeholder scan:** No TBD/TODO. Chart/add-on versions are pinned with an explicit build-time verification command each (an environment check, like the EKS-version pin in Plan 2) — not placeholders.

**3. Consistency:** IRSA helper module invocations all use `module.eks.oidc_provider_arn` (Plan 2 output) and the correct `namespace:serviceaccount` subjects matching each chart's SA (`kube-system:aws-load-balancer-controller`, `external-secrets:external-secrets`, `kube-system:cluster-autoscaler`, `amazon-cloudwatch:cloudwatch-agent`). ESO's `external_secrets_secrets_manager_arns` references `aws_secretsmanager_secret.app.arn` (Plan 2). Provider exec auth uses `module.eks.cluster_name`/`cluster_endpoint`/`cluster_certificate_authority_data` (Plan 2 module outputs). ✅

**Build-time environment checks (not placeholders):** confirm each chart version against K8s 1.34 (`helm search repo … --versions`) and the CloudWatch add-on version (`aws eks describe-addon-versions … --kubernetes-version 1.34`); bump if the pinned value is unavailable.
