# EFS CSI driver and the StorageClass that consumes it.
#
# The filesystem, its security group and its mount targets live in modules/storage -- they are AWS
# storage like the bucket and the registries, and the "WHY EFS AND NOT EBS" reasoning moved there
# with them. What stays here is the in-cluster half: the driver add-on and the StorageClass.


module "efs_csi_irsa" {
  # Submodule path, matching every other IRSA role in this stack (addon-alb.tf,
  # addon-eso.tf, addon-external-dns.tf ...). The registry-root form
  # "terraform-aws-modules/iam-role-for-service-accounts-eks/aws" does not exist and fails
  # at `terraform init`.
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = module.efs_csi_irsa.iam_role_arn

  # The mount targets must exist before the driver tries to use the filesystem. They live in
  # modules/storage, so this depends on the module as a whole.
  depends_on = [module.storage]
}

resource "kubernetes_storage_class" "efs" {
  metadata { name = "efs-sc" }

  storage_provisioner = "efs.csi.aws.com"

  parameters = {
    provisioningMode = "efs-ap" # dynamic access points, one per PVC
    fileSystemId     = module.storage.efs_file_system_id
    directoryPerms   = "700"
    # JENKINS_HOME must be owned by uid/gid 1000 -- the controller runs non-root and cannot chown a
    # root-owned mount, which surfaces as a boot loop with "Failed to create directory" rather than
    # a permissions error.
    uid = "1000"
    gid = "1000"
  }

  # Retain, not Delete: an accidental `helm uninstall` of Jenkins must not take the build history
  # with it. `terraform destroy` still removes the filesystem itself.
  reclaim_policy = "Retain"

  depends_on = [aws_eks_addon.efs_csi]
}
