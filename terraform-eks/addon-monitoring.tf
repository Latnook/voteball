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
  # Grafana admin password lives only in-cluster (a Secret); rotate for real use. Demo default below.
  set {
    name  = "grafana.adminPassword"
    value = "voteball-admin" # demo only -- change / use a Secret for anything real
  }
}
