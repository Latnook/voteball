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

  # Alertmanager -> SNS. Closes docs/production-readiness.md section 6: alerts existed nowhere and
  # Alertmanager routed nowhere, which makes collected metrics archaeology rather than monitoring.
  #
  # A `values` block rather than more `set` entries: the routing tree is nested and set-strings for
  # it are unreadable and easy to get subtly wrong. yamlencode also keeps the ARNs as references
  # instead of hand-copied strings.
  #
  # The alert RULES live in the app chart (charts/voteball/templates/prometheusrule.yaml), not here:
  # they describe the application, so they belong with it and ship through ArgoCD on a normal commit
  # rather than requiring a Terraform apply to change a threshold.
  values = [yamlencode({
    # EKS runs the control plane (scheduler, controller-manager, etcd) and kube-proxy on AWS-managed
    # infrastructure Prometheus cannot reach, so scraping them yields nothing but a permanently-firing
    # KubeSchedulerDown / KubeControllerManagerDown / etcd / KubeProxyDown. Disabling each drops both
    # its ServiceMonitor (the unreachable target) AND its *Down rule -- the chart gates the rule file
    # on the same .enabled flag. kubeApiServer is deliberately LEFT enabled: its metrics ARE exposed
    # on EKS, and its recording rules feed real dashboards.
    kubeScheduler         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }

    alertmanager = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alertmanager.arn
        }
      }
      config = {
        # This `config` REPLACES the chart's default Alertmanager config wholesale -- which silently
        # dropped its default inhibit_rules. Without them, info-severity alerts are never suppressed,
        # and the InfoInhibitor meta-alert (label severity=none, so not caught by any severity route)
        # falls straight through to SNS. Re-add the standard inhibition tree here, and null-route
        # InfoInhibitor itself below so the machinery never emails a human.
        inhibit_rules = [
          # A firing critical mutes matching warning/info in the same namespace + alertname.
          {
            source_matchers = ["severity = critical"]
            target_matchers = ["severity =~ \"warning|info\""]
            equal           = ["namespace", "alertname"]
          },
          # A firing warning mutes the matching info.
          {
            source_matchers = ["severity = warning"]
            target_matchers = ["severity = info"]
            equal           = ["namespace", "alertname"]
          },
          # InfoInhibitor mutes info alerts that are alone in a namespace. It stops firing the instant
          # a warning/critical appears there, so a correlated info alert resurfaces alongside the real
          # one -- "noisy by themselves, relevant when combined", which is the whole point of it.
          {
            source_matchers = ["alertname = InfoInhibitor"]
            target_matchers = ["severity = info"]
            equal           = ["namespace"]
          },
        ]
        route = {
          receiver = "sns"
          # Batch related alerts: a node going away fires several at once, and one message about
          # five problems is read where five messages about one problem are filtered out.
          group_by       = ["alertname", "namespace"]
          group_wait     = "30s"
          group_interval = "5m"
          # Deliberately long. This topic emails a human, and a 4-hourly reminder about a known
          # problem is how an alert channel becomes background noise.
          repeat_interval = "12h"
          routes = [
            {
              # Prometheus' own always-firing heartbeat. It exists to prove the pipeline is alive
              # when scraped by a dead-man's-switch; delivered to a mailbox it is pure noise.
              matchers = ["alertname = Watchdog"]
              receiver = "null"
            },
            {
              # InfoInhibitor is machinery for the inhibit_rules above, never a human-facing alert.
              matchers = ["alertname = InfoInhibitor"]
              receiver = "null"
            },
          ]
        }
        receivers = [
          { name = "null" },
          {
            name = "sns"
            sns_configs = [
              {
                topic_arn = aws_sns_topic.notifications.arn
                sigv4     = { region = var.aws_region }
                subject   = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
                message   = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ .Annotations.description }}\n\n{{ end }}"
              }
            ]
          }
        ]
      }
    }
  })]

  # Same ALB-webhook race as addon-cloudwatch.tf's aws_eks_addon.cloudwatch: this chart's Services
  # (Prometheus/Grafana/Alertmanager) can hit the aws-load-balancer-webhook-service before its backend
  # pods are Ready if created in parallel with the ALB release. Hit on 2026-07-20 apply.
  depends_on = [helm_release.aws_load_balancer_controller]
}
