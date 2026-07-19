# EKS GitOps + Observability — Plan 4

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer continuous delivery and monitoring onto the live EKS app — ArgoCD adopting `charts/voteball` as a GitOps `Application`, a GitHub Actions pipeline (OIDC → build → Trivy scan → ECR → tag-bump → ArgoCD auto-sync), and kube-prometheus-stack (Prometheus + Grafana, metrics).

**Architecture:** ArgoCD + kube-prometheus-stack install as `terraform-eks` add-ons (`helm_release`). A GitHub OIDC provider + a repo-scoped IAM role (Terraform) let GitHub Actions push to ECR with **no stored keys**. An ArgoCD `Application` (committed at `argocd/voteball-application.yaml`) watches `github.com/Latnook/voteball` (public — no deploy key) `master` `charts/voteball` and auto-syncs `devops-app`, *adopting* the currently helm-installed resources in place. The chart stays the single source of truth; ArgoCD is the delivery mechanism, CI just builds/scans/pushes and bumps the image tag.

**Tech Stack:** EKS 1.34, ArgoCD (argo/argo-cd chart), kube-prometheus-stack (prometheus-community), GitHub Actions + `aws-actions/configure-aws-credentials` OIDC + `aquasecurity/trivy-action`, `helm`, region `il-central-1`, account `590183895228`, repo `Latnook/voteball`.

## Global Constraints

- Extends `terraform-eks/` (add-ons) + `charts/voteball` (unchanged; ArgoCD manages it) + new `argocd/` and `.github/workflows/`.
- **No long-lived AWS keys** — CI uses OIDC federation to a repo-scoped role.
- **No secrets in git** — ArgoCD needs none (public repo); the CI role ARN is a GitHub **repo variable** (not a secret), set manually.
- **UIs are not public** — ArgoCD + Grafana via `kubectl port-forward` only (no Ingress/ALB).
- kube-prometheus-stack = **metrics only** (logs already flow to CloudWatch, Plan 2b); cap Prometheus retention/resources to fit the nodes (Cluster Autoscaler adds a node if needed).
- Verify chart/action versions live (`helm search repo … --versions`). **Commit and push to `master` as each task completes.** Never force-push.
- **Trim note:** this is the design's *first* bonus to cut. If abandoned mid-way, the app keeps running (helm-managed) — nothing here is load-bearing for the app.

**Pre-flight:** app live (Plan 3b), `kubectl`/`helm`/`terraform` working, `gh` CLI or GitHub repo admin access (to set the repo variable).

---

### Task 1: kube-prometheus-stack (Prometheus + Grafana)

**Files:** Create `terraform-eks/addon-monitoring.tf`

- [ ] **Step 1: Verify chart version** — `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null; helm repo update >/dev/null; helm search repo prometheus-community/kube-prometheus-stack --versions | head -3`

- [ ] **Step 2: Create `terraform-eks/addon-monitoring.tf`**

```hcl
# kube-prometheus-stack: Prometheus + Grafana + node-exporter + kube-state-metrics. Metrics only
# (logging is CloudWatch, Plan 2b). Retention + resources are capped to keep the node RAM budget sane;
# Cluster Autoscaler adds a node if the scheduler needs it. UIs are ClusterIP (port-forward, not public).
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.5.1" # verify via `helm search repo` at build time
  namespace        = "monitoring"
  create_namespace = true

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "6h"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "400Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.memory"
    value = "900Mi"
  }
  # Grafana admin password lives only in-cluster (Secret); rotate for real use. Demo default below.
  set {
    name  = "grafana.adminPassword"
    value = "voteball-admin" # demo only -- change / use a Secret for anything real
  }
}
```

- [ ] **Step 3: Init + apply + verify**

```bash
cd terraform-eks && terraform init -input=false && terraform apply -var-file=voteball-eks.tfvars && cd ..
kubectl get pods -n monitoring                 # prometheus, grafana, operator, node-exporter, kube-state-metrics Running
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
# browse http://localhost:3000  (admin / voteball-admin) -> Dashboards -> "Kubernetes / Compute Resources / Namespace (Pods)"
```
Expected: monitoring pods Running; Grafana loads with cluster/pod dashboards populated (metrics-server + node-exporter feeding).

- [ ] **Step 4: Commit** — `git add terraform-eks/addon-monitoring.tf && git commit -m "Add kube-prometheus-stack (Prometheus + Grafana, metrics)" && git push`

---

### Task 2: ArgoCD (install)

**Files:** Create `terraform-eks/addon-argocd.tf`

- [ ] **Step 1: Verify chart version** — `helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null; helm repo update >/dev/null; helm search repo argo/argo-cd --versions | head -3`

- [ ] **Step 2: Create `terraform-eks/addon-argocd.tf`**

```hcl
# ArgoCD: GitOps delivery. UI is ClusterIP (port-forward, not public). No repo credentials needed --
# the Voteball repo is public, so ArgoCD reads it over unauthenticated HTTPS.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.0" # verify via `helm search repo` at build time
  namespace        = "argocd"
  create_namespace = true
}
```

- [ ] **Step 3: Apply + get the initial admin password**

```bash
cd terraform-eks && terraform apply -var-file=voteball-eks.tfvars && cd ..
kubectl get pods -n argocd    # argocd-server, repo-server, application-controller, redis, dex Running
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward -n argocd svc/argocd-server 8080:443 &   # browse https://localhost:8080 (user admin)
```
Expected: ArgoCD pods Running; UI reachable with the printed admin password.

- [ ] **Step 4: Commit** — `git add terraform-eks/addon-argocd.tf && git commit -m "Add ArgoCD (GitOps delivery)" && git push`

---

### Task 3: ArgoCD Application — adopt the app as GitOps

**Files:** Create `argocd/voteball-application.yaml`

- [ ] **Step 1: Create `argocd/voteball-application.yaml`**

```yaml
# ArgoCD watches the public repo's charts/voteball on master and keeps devops-app in sync.
# ServerSideApply adopts the resources helm already created (no delete/redeploy, so the ALB is not
# re-provisioned). prune+selfHeal make git the source of truth going forward.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: voteball
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Latnook/voteball
    targetRevision: master
    path: charts/voteball
  destination:
    server: https://kubernetes.default.svc
    namespace: devops-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true   # adopt existing helm-created resources in place
      - CreateNamespace=false  # devops-app already exists
```

- [ ] **Step 2: Apply the Application + let ArgoCD adopt**

```bash
kubectl apply -f argocd/voteball-application.yaml
kubectl get application voteball -n argocd -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}'
```
Expected: `Synced / Healthy` within ~1-2 min (ArgoCD adopts the running resources; no downtime, ALB unchanged).

- [ ] **Step 3: Retire the stale helm release record (ArgoCD owns it now)**

```bash
# ArgoCD manages the live resources; remove helm's now-orphaned release bookkeeping so the two don't
# both claim ownership. This deletes only helm's tracking Secret, not any running resource.
kubectl delete secret -n devops-app -l "owner=helm,name=voteball"
helm list -n devops-app    # voteball no longer listed; app still Running
```
*Fallback if adoption conflicts:* `helm uninstall voteball -n devops-app` then let ArgoCD re-create (brief downtime + ALB re-provision + external-dns re-point).

- [ ] **Step 4: Commit** — `git add argocd/voteball-application.yaml && git commit -m "ArgoCD Application: adopt charts/voteball as GitOps (auto-sync)" && git push`

---

### Task 4: GitHub OIDC provider + CI IAM role (Terraform)

**Files:** Create `terraform-eks/github-oidc.tf`; Modify `terraform-eks/outputs.tf`

- [ ] **Step 1: Create `terraform-eks/github-oidc.tf`**

```hcl
# Lets GitHub Actions assume a scoped role via OIDC -- no long-lived AWS keys. The trust is limited to
# this repo; the permissions are ECR push to the voteball-* repos only.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:Latnook/voteball:*"] # this repo only (any branch/tag)
    }
  }
}

data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken is account-wide by design
  }
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn] # voteball-backend/worker/nginx/backup only
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.cluster_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "${var.cluster_name}-github-actions-ecr"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
```

- [ ] **Step 2: Add the role ARN output to `terraform-eks/outputs.tf`**

```hcl
output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC (set as the repo variable AWS_ROLE_ARN)."
  value       = aws_iam_role.github_actions.arn
}
```

- [ ] **Step 3: Init + apply + capture the ARN**

```bash
cd terraform-eks && terraform init -input=false && terraform apply -var-file=voteball-eks.tfvars
terraform output -raw github_actions_role_arn ; echo ; cd ..
```
Expected: `Apply complete!`; the role ARN printed.

- [ ] **Step 4: Commit** — `git add terraform-eks/github-oidc.tf terraform-eks/outputs.tf terraform-eks/.terraform.lock.hcl && git commit -m "Add GitHub OIDC provider + repo-scoped ECR-push role for CI" && git push`

---

### Task 5: GitHub Actions CI/CD workflow

**Files:** Create `.github/workflows/ci.yml`

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: build-scan-push-deploy
on:
  push:
    branches: [master]
    paths:
      - "ansible-project/roles/backend/files/backend/**"
      - "ansible-project/roles/worker/files/worker/**"
      - "ansible-project/roles/frontend/files/nginx/**"
      - "docker/backup/**"
      - ".github/workflows/ci.yml"

permissions:
  id-token: write   # OIDC federation to AWS
  contents: write   # commit the image-tag bump back to the repo

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      REGION: il-central-1
      REGISTRY: 590183895228.dkr.ecr.il-central-1.amazonaws.com
    steps:
      - uses: actions/checkout@v4

      - name: Set image tag (short SHA)
        run: echo "TAG=$(git rev-parse --short HEAD)" >> "$GITHUB_ENV"

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}   # repo variable = terraform output github_actions_role_arn
          aws-region: ${{ env.REGION }}

      - uses: aws-actions/amazon-ecr-login@v2

      - name: Build, scan (Trivy), push
        run: |
          set -euo pipefail
          declare -A CTX=(
            [voteball-backend]=ansible-project/roles/backend/files/backend
            [voteball-worker]=ansible-project/roles/worker/files/worker
            [voteball-nginx]=ansible-project/roles/frontend/files/nginx
            [voteball-backup]=docker/backup
          )
          for repo in "${!CTX[@]}"; do
            img="${REGISTRY}/${repo}:${TAG}"
            docker build -t "$img" "${CTX[$repo]}"
          done

      - name: Trivy scan (fail on CRITICAL/HIGH)
        uses: aquasecurity/trivy-action@0.24.0
        with:
          scan-type: image
          image-ref: ${{ env.REGISTRY }}/voteball-backend:${{ env.TAG }}
          severity: CRITICAL,HIGH
          exit-code: "1"
          ignore-unfixed: true

      - name: Push images
        run: |
          set -euo pipefail
          for repo in voteball-backend voteball-worker voteball-nginx voteball-backup; do
            docker push "${REGISTRY}/${repo}:${TAG}"
          done

      - name: Bump image tag in the chart and commit (ArgoCD auto-syncs)
        run: |
          set -euo pipefail
          sed -i -E "s/^  tag: \".*\"/  tag: \"${TAG}\"/" charts/voteball/values.yaml
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add charts/voteball/values.yaml
          git commit -m "ci: image tag ${TAG} [skip ci]" || echo "no tag change"
          git push
```

*Note:* the `[skip ci]` on the bump commit stops it from re-triggering the workflow. ArgoCD sees the new `values.yaml` on `master` and rolls the Deployments to `${TAG}`.

- [ ] **Step 2: Lint the workflow (yaml) + commit**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('workflow yaml ok')"
git add .github/workflows/ci.yml
git commit -m "Add GitHub Actions CI: build -> Trivy -> ECR (OIDC) -> tag bump -> ArgoCD sync"
git push
```

---

### Task 6: Wire the repo variable + verify the pipeline (STOP for user)

- [ ] **Step 1: MANUAL OP — set the repo variable `AWS_ROLE_ARN`**

```bash
# needs gh CLI authenticated with repo admin (or set it in GitHub UI: Settings > Secrets and variables
# > Actions > Variables > New repository variable, name AWS_ROLE_ARN):
gh variable set AWS_ROLE_ARN --repo Latnook/voteball \
  --body "$(terraform -chdir=terraform-eks output -raw github_actions_role_arn)"
```

- [ ] **Step 2: Trigger + watch the pipeline**

```bash
# Any push touching a watched path runs it (or re-run the latest from the Actions tab). Watch:
gh run watch --repo Latnook/voteball
```
Expected: job succeeds — images built, Trivy passes, pushed to ECR, a `ci: image tag <sha> [skip ci]` commit appears on `master`.

- [ ] **Step 3: Verify ArgoCD rolled the new tag**

```bash
kubectl get application voteball -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
kubectl get deploy backend -n devops-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # -> new SHA
```
Expected: `Synced/Healthy`; the running image tag matches the CI-pushed SHA.

- [ ] **Step 4: STOP — report to the user**

Report: Grafana up (metrics dashboards), ArgoCD adopted the app (Synced/Healthy, git is now the source of truth), the CI pipeline builds→Trivy→ECR→tag-bump and ArgoCD auto-syncs it. Offer Plan 5 (submission docs) or teardown. Note the one manual op (the repo variable) and that ArgoCD/Grafana are port-forward-only (not public).

---

## Self-Review

**1. Coverage:** ArgoCD install (T2) + Application adopting the app (T3); GitHub OIDC + role (T4) + Actions pipeline with Trivy (T5) + wiring/verify (T6); kube-prometheus-stack (T1). Matches the design's Plan 4 (GitOps + CI/CD + observability). ✅

**2. Placeholder scan:** chart/action versions have build-time verify notes; `${{ vars.AWS_ROLE_ARN }}` is a documented manual repo-variable (T6), not a placeholder. No TODO/TBD in logic.

**3. Consistency:** the OIDC role's ECR resources = `aws_ecr_repository.app` (Plan 2/3b, the 4 repos the workflow pushes). The workflow's `REGISTRY` + repo names match `scripts/build-push-ecr.sh` and the chart's `image.registry`. The tag-bump `sed` targets the same `image.tag` line the chart reads. ArgoCD `repoURL`/`path`/`namespace` = the public repo + `charts/voteball` + `devops-app`. ✅

**Known checks at build time:** GitHub OIDC thumbprint via the `tls` data source (already a provider dep from the EKS module); confirm `gh` is authenticated for the repo-variable step; the first CI run also validates the OIDC trust (`sub = repo:Latnook/voteball:*`) end-to-end.
