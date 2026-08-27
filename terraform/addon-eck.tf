# Elastic Cloud on Kubernetes (ECK) -- the operator that reconciles the Elasticsearch and Kibana
# custom resources in charts/logging. See docs/design/2026-08-27-efk-logging-design.md.
#
# THIS IS A PLATFORM ADD-ON, NOT THE APPLICATION -- the same class as ArgoCD, ESO, external-dns and
# kube-prometheus-stack. It reaches the cluster by `terraform apply`, never by a git push. Committing
# a version bump here and walking away does nothing.
#
# WHY TERRAFORM RATHER THAN ArgoCD: the chart installs 17 CLUSTER-SCOPED objects -- 12 CRDs, 3
# ClusterRoles, 1 ClusterRoleBinding, 1 ValidatingWebhookConfiguration. Both AppProjects in
# argocd/voteball-application.yaml.tmpl set `clusterResourceWhitelist: []`, a deliberate blast-radius
# limit, so ArgoCD is structurally unable to manage this. The namespaced Elasticsearch/Kibana/Fluentd
# objects ARE eligible and live in charts/logging.
#
# WHY NOT BY HAND: a hand-run `helm install` is invisible to Terraform, so it silently disappears on
# every rebuild of this cluster -- and scripts/destroy.sh pre-uninstalls a KNOWN list of releases
# while the cluster is still healthy. An unknown release owning a ValidatingWebhookConfiguration is
# exactly the shape that hangs teardown: the webhook intercepts deletes of *.k8s.elastic.co objects,
# and with the operator already gone there is no backend to answer.
resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = "3.5.0" # verified latest via `helm search repo elastic/eck-operator --versions` (2026-08-27)
  namespace        = "elastic-system"
  create_namespace = true

  # The operator's own StatefulSet already requests only 100m/150Mi and already runs
  # runAsNonRoot / allowPrivilegeEscalation:false / readOnlyRootFilesystem:true out of the box, so
  # there is nothing to override for this repo's container-security bar.
  #
  # helm provider v3: `set` is a LIST of attribute maps, never a `set {}` block (see versions.tf).
  set = [
    {
      # Watch only the namespace charts/logging deploys into. The default is every namespace, which
      # would have the operator reconciling CRs anywhere in the cluster. Verified against
      # `helm show values elastic/eck-operator --version 3.5.0` and by rendering the chart with this
      # value set: the operator's own config carries `namespaces: [logging]`.
      name  = "managedNamespaces[0]"
      value = "logging"
    },
  ]

  depends_on = [module.eks]
}
