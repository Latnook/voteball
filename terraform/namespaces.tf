# Kubernetes namespaces this stack owns.
#
# `ci` is deliberately NOT here -- it lives in addon-jenkins.tf beside the releases that install into
# it, carrying a long comment about the EKS access-entry race it has to wait out. Only devops-app
# lives here, because it belongs to the application rather than to any single add-on.

# The application namespace. Terraform creates it even though Terraform manages nothing that RUNS in
# it -- the three Deployments arrive via ArgoCD from charts/voteball. It has to exist this early
# because charts/jenkins-support places the CD pipeline's read-only Role and RoleBinding inside it
# (rbac.yaml, keyed on `appNamespace`), and Kubernetes will not create a namespaced object in a
# namespace that does not exist yet.
#
# Until 2026-08-05 nothing created it until `helm upgrade --install ... --create-namespace` in
# scripts/deploy.sh, which runs several steps AFTER `terraform apply`. That ordering was harmless
# until the 2026-08-04 CI/CD split introduced those two objects, and it then failed every
# from-scratch apply with:
#
#   Error: Helm release error ... 2 errors occurred:
#       * namespaces "devops-app" not found
#       * namespaces "devops-app" not found     (one per object)
#
# while continuing to apply cleanly against any cluster where an earlier deploy had already created
# the namespace -- the same "passes on a live cluster, breaks only on a rebuild from empty state"
# shape as the EFS for_each bug fixed in b4fee26 the same day.
#
# Knock-on effects, both benign: deploy.sh's `--create-namespace` becomes a no-op (Helm creates a
# namespace only when it is missing), and ArgoCD's `CreateNamespace=false` in
# argocd/voteball-application.yaml.tmpl stays correct -- the namespace really does already exist by
# the time the Application is created. `terraform destroy` now deletes this namespace explicitly,
# which is what CLAUDE.md's teardown notes already described it as doing.
resource "kubernetes_namespace" "devops_app" {
  # Same EKS access-entry propagation race as kubernetes_namespace.ci -- see the comment there for
  # what it looks like when it bites (a permissions error ~13 minutes into an apply).
  # AND on helm_release.external_secrets, which is a DESTROY-order constraint, not a create-order
  # one. Terraform destroys dependents before their dependencies, so naming ESO here is what makes
  # this namespace go FIRST and the ESO controller outlive it.
  #
  # That requirement was documented long before it was enforced. The ExternalSecret and SecretStore
  # inside this namespace carry finalizers only the ESO controller can clear, which is exactly why
  # ESO is deliberately excluded from destroy.sh's pre-uninstall list. But nothing expressed the
  # ordering to Terraform, so it scheduled both in the SAME parallel batch: on the 2026-09-07
  # teardown `helm_release.external_secrets: Destroying...` was printed one line BEFORE the
  # namespaces started, and the run failed with "context deadline exceeded".
  #
  # A documented invariant with no mechanism is not an invariant. This is the mechanism.
  depends_on = [module.compute, helm_release.external_secrets]

  metadata {
    name = "devops-app"

    labels = {
      # Kubernetes has set this automatically since 1.21, and it is declared here for the same reason
      # kubernetes_namespace.ci declares it: NetworkPolicy namespaceSelectors match on it, and a
      # selector silently matching nothing is far harder to spot than a missing namespace.
      "kubernetes.io/metadata.name" = "devops-app"

      # Vestigial, and declared anyway. This namespace predates Terraform owning it -- until
      # 2026-08-05 it was created by `helm upgrade --install --create-namespace` in deploy.sh (see
      # the history above), which left this label behind. Terraform adopted the namespace but never
      # declared the label, so it sat as live drift: `terraform plan` proposed removing it on every
      # run, and the 2026-09-07 module refactor had to be gated against that one known change rather
      # than against a clean plan.
      #
      # NOTHING SELECTS ON IT -- every namespaceSelector in this repo matches
      # kubernetes.io/metadata.name above, and neither `logging` nor `ci` carries it. It is declared
      # purely so config and cluster agree, which also means a destroy/rebuild reproduces the
      # namespace exactly as it is today. Deleting this line is safe; letting an apply delete it
      # silently was not.
      "name" = "devops-app"
    }
  }
}

# The logging namespace. Terraform creates it for the same reason it creates devops-app: the objects
# that RUN in it arrive via ArgoCD from charts/logging, but the namespace has to exist before the
# ECK operator's managedNamespaces setting can name it, and before ArgoCD's CreateNamespace=false
# Application tries to sync into it.
#
# `kubectl create namespace logging` is deliberately NOT used anywhere. A namespace created outside
# Terraform is not deleted on destroy -- it lingers or sits Terminating, and the next apply collides
# with it.
resource "kubernetes_namespace" "logging" {
  # Same EKS access-entry propagation race as kubernetes_namespace.devops_app above.
  depends_on = [module.compute]

  metadata {
    name = "logging"

    labels = {
      # NetworkPolicy namespaceSelectors match on this, and a selector silently matching nothing is
      # far harder to spot than a missing namespace. charts/logging's allow-fluentbit-ingest rule
      # depends on amazon-cloudwatch carrying the equivalent label.
      "kubernetes.io/metadata.name" = "logging"
    }
  }
}
