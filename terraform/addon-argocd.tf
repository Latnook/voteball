# ArgoCD (argo/argo-cd): GitOps delivery. UI is ClusterIP (port-forward, not public). No repo
# credentials needed -- the Voteball repo is public, so ArgoCD reads it over unauthenticated HTTPS.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.2.1" # verified latest via `helm search repo` on 2026-07-30 (app v3.4.5)
  namespace        = "argocd"
  create_namespace = true

  # How fast a push to master reaches the cluster. The chart defaults to a 120s poll plus up to 60s
  # of jitter, so Jenkins' `ci: image tag <sha> [skip ci]` commit sat for 120-180s before ArgoCD
  # even looked at git -- longer than the rollout that followed it.
  #
  # The jitter is there so a cluster with hundreds of Applications does not stampede its git host on
  # one tick. This cluster has exactly ONE Application, against a public GitHub repo, so the cost of
  # polling four times as often is an extra `ls-remote` every 30s from argocd-repo-server. If a
  # second Application is ever added, revisit the numbers rather than assuming they still scale.
  #
  # This was chosen over pushing a sync from CI (a `curl` to argocd-server's /api/webhook, or an
  # ArgoCD API token in Jenkins credentials). Both would be near-instant, and both cost more than
  # the ~30s they save: the webhook needs a hole in the `ci` egress NetworkPolicy, which is written
  # as "the whole internet EXCEPT this VPC" precisely so CI cannot reach RDS or devops-app; the API
  # token would give Jenkins the ability to deploy, which the Jenkinsfile header states it must not
  # have. Exposing argocd-server on its own Ingress is worse still -- ALB group `voteball` would
  # gain a third member, and scripts/destroy.sh deletes two, leaking the ALB.
  #
  # Keys contain literal dots (argocd-cm is a flat map, not nested YAML) -- hence the quoting.
  # Helm merges this map over the chart's other `configs.cm` defaults; it does not replace them.
  values = [yamlencode({
    configs = {
      cm = {
        "timeout.reconciliation"        = "30s"
        "timeout.reconciliation.jitter" = "10s"
      }
    }
  })]
}
