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
  depends_on = [module.eks]

  metadata {
    name = "devops-app"

    labels = {
      # Kubernetes has set this automatically since 1.21, and it is declared here for the same reason
      # kubernetes_namespace.ci declares it: NetworkPolicy namespaceSelectors match on it, and a
      # selector silently matching nothing is far harder to spot than a missing namespace.
      "kubernetes.io/metadata.name" = "devops-app"
    }
  }
}
