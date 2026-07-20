# kube-prometheus-stack (prometheus-community): Prometheus + Grafana + node-exporter + kube-state-metrics.
# Metrics only (logging is CloudWatch, Plan 2b). Retention + resources are capped to keep the node RAM
# budget sane; Cluster Autoscaler adds a node if the scheduler needs it. UIs are ClusterIP (port-forward,
# not public).
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "87.17.0" # verified latest via `helm search repo` on 2026-07-19 (app v0.92.1)
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
  # NOTE: Grafana's admin password is deliberately NOT set here -- hardcoding it would put a credential
  # in git and terraform.tfstate. The chart auto-generates a random password stored only in the
  # in-cluster Secret. Retrieve it (Grafana UI is port-forward-only, never public) with:
  #   kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  #     -o jsonpath='{.data.admin-password}' | base64 -d

  # Same ALB-webhook race as addon-cloudwatch.tf's aws_eks_addon.cloudwatch: this chart's Services
  # (Prometheus/Grafana/Alertmanager) can hit the aws-load-balancer-webhook-service before its backend
  # pods are Ready if created in parallel with the ALB release. Hit on 2026-07-20 apply.
  depends_on = [helm_release.aws_load_balancer_controller]
}
