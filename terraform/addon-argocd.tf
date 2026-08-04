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
  #
  # Everything ArgoCD is configured with is in this block or in argocd/voteball-application.yaml.tmpl.
  # Nothing is set through the UI -- `scripts/render-argocd-app.sh --check` fails if that stops being
  # true. Settings changed in the UI would live in argocd-cm, which this release owns, so the next
  # `terraform apply` reverts them anyway; the check is what makes that visible rather than silent.
  values = [yamlencode({
    configs = {
      cm = {
        "timeout.reconciliation"        = "30s"
        "timeout.reconciliation.jitter" = "10s"

        # The chart ships the literal placeholder `https://argocd.example.com`. ArgoCD builds the
        # links in its own UI and API responses from this, so leaving it means every "open in ArgoCD"
        # link points at a domain nobody owns. There is no public ArgoCD endpoint by design (the
        # Service is ClusterIP -- see docs/deploy.md), so the honest value is the port-forward the
        # runbook actually tells you to use.
        "url" = "https://localhost:8081"

        # A local account for the CD pipeline, so Jenkins does not use the admin account. apiKey
        # only -- this account cannot log into the UI, it can only hold an API token.
        "accounts.jenkins-cd" = "apiKey"
      }

      # `policy.default` stays "" -- codifying the DEFAULT, on purpose, same reasoning as before:
      # anyone arriving by any route other than the two identities named below (admin, jenkins-cd)
      # gets nothing. `policy.csv` is no longer empty: it grants the jenkins-cd account exactly
      # enough to run the CD pipeline, and nothing else.
      rbac = {
        "policy.default" = ""
        # Least privilege for the CD pipeline: it may sync and inspect the one Application it
        # deploys, and nothing else. No create, no delete, no access to any other Application, no
        # cluster or repo administration.
        "policy.csv" = <<-EOT
          p, role:jenkins-cd, applications, get,  voteball/voteball, allow
          p, role:jenkins-cd, applications, sync, voteball/voteball, allow
          g, jenkins-cd, role:jenkins-cd
        EOT
      }
    }

    # Two components the chart runs by default and this deployment has no configuration for. Left on,
    # they are a running SSO server with no connectors and a notifications controller with no
    # triggers -- state in the cluster that no file in this repo asks for, which is the same problem
    # as a UI-made setting. Off, the intent is explicit. Re-enable with one line and `terraform apply`.
    #
    # NOT disabled: the ApplicationSet controller. Chart 10.2.1 dropped `applicationSet.enabled`, and
    # the only remaining lever is `replicas: 0`, which leaves a permanently-unready Deployment behind
    # -- worse than the idle pod it removes.
    dex           = { enabled = false }
    notifications = { enabled = false }
  })]
}
