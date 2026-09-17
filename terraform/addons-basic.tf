# metrics-server (Kubernetes SIG, official): supplies CPU/memory metrics to the Kubernetes metrics
# API, which the app's HPA (Plan 3) reads. No AWS permissions -- pure in-cluster.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0" # verified latest via `helm search repo` on 2026-09-17 (app v0.9.0, built against K8s 1.36)
  namespace  = "kube-system"
}

# AWS Node Termination Handler (AWS, official; IMDS mode): watches the node's own instance metadata
# for the 2-minute Spot interruption notice and cordons+drains the node so pods reschedule cleanly
# instead of being hard-killed. IMDS mode needs only in-cluster RBAC (cordon/drain) -- no IRSA.
resource "helm_release" "node_termination_handler" {
  name       = "aws-node-termination-handler"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
  version    = "0.21.0" # verified latest via `helm search repo` on 2026-07-19 (app v1.19.0)
  namespace  = "kube-system"

  set = [
    {
      name  = "enableSpotInterruptionDraining"
      value = "true"
    },
  ]
}
