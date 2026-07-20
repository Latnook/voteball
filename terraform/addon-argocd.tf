# ArgoCD (argo/argo-cd): GitOps delivery. UI is ClusterIP (port-forward, not public). No repo
# credentials needed -- the Voteball repo is public, so ArgoCD reads it over unauthenticated HTTPS.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.1.4" # verified latest via `helm search repo` on 2026-07-19 (app v3.4.5)
  namespace        = "argocd"
  create_namespace = true
}
