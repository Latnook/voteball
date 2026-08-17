# EBS CSI driver + a gp3 StorageClass, for the Prometheus PVC in addon-monitoring.tf.
#
# WHY EBS HERE AND EFS FOR JENKINS -- opposite choices from the same constraint, deliberately.
# addon-efs.tf chose EFS for JENKINS_HOME because an EBS volume is locked to a single Availability
# Zone and this node group is 100% Spot. That reasoning does not transfer: Prometheus' TSDB is
# explicitly unsupported on network filesystems, where its memory-mapped, fsync-ordered writes can
# corrupt the database. The price is the AZ lock-in -- if the node holding the volume is reclaimed
# and its replacement lands in the other AZ, the Prometheus pod sits Pending until an AZ-a node
# exists again. That is acceptable ONLY because the data is disposable: 15 days of metrics, not 15
# days of votes. Recovery is deleting the PVC and losing history. Do not "make these consistent".
module "ebs_csi_irsa" {
  # Submodule path, matching every other IRSA role in this stack. The registry-root form
  # "terraform-aws-modules/iam-role-for-service-accounts-eks/aws" does not exist and fails at init.
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
}

resource "kubernetes_storage_class" "gp3" {
  metadata { name = "gp3" }

  storage_provisioner = "ebs.csi.aws.com"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # WaitForFirstConsumer, not Immediate: the volume must be created in the SAME Availability Zone as
  # the node that will mount it. Immediate binding picks an AZ before the scheduler has chosen a
  # node, which can strand the pod in Pending forever with a volume it cannot reach.
  volume_binding_mode = "WaitForFirstConsumer"

  # Delete, NOT the Retain that efs-sc uses. Retain exists for Jenkins so an accidental uninstall
  # cannot take the build history with it. Here it would mean a teardown that silently leaves a
  # billed EBS volume behind with nothing in Terraform's records pointing at it -- and unlike a
  # leftover ENI, an orphaned volume blocks nothing, so the destroy reports success.
  reclaim_policy = "Delete"

  depends_on = [aws_eks_addon.ebs_csi]
}
