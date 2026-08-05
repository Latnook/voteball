# Persistent storage for JENKINS_HOME.
#
# WHY EFS AND NOT EBS. The course brief requires a PersistentVolumeClaim. The 2026-07-30 design
# rejected one and set persistence = false, for a real reason: this node group is 100% Spot and gets
# reclaimed roughly daily, and an EBS volume is locked to a single Availability Zone -- so every
# reschedule must land back in that AZ or the pod hangs Pending forever, which is the one failure
# mode in this design that needs a human.
#
# That reasoning is specific to EBS. EFS is an NFS filesystem with a mount target in every private
# subnet, reachable from every AZ, so the pod can be rescheduled anywhere. The requirement is met
# without reintroducing the AZ lock.
#
# What does NOT change: JCasC remains the source of truth and the controller still rebuilds itself
# entirely from code. Losing this volume stays a recoverable event. Nothing may start depending on
# its contents.

resource "aws_efs_file_system" "jenkins" {
  creation_token = "${var.cluster_name}-jenkins-home"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = { Name = "${var.cluster_name}-jenkins-home" }
}

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs"
  description = "NFS from EKS nodes to the Jenkins home filesystem"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${var.cluster_name}-efs" }
}

# Source is the node security group, NOT a CIDR. A CIDR rule would also admit anything else that
# happens to sit in these subnets; this admits only traffic from the cluster's own nodes.
resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from EKS worker nodes"
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

# One mount target per private subnet -- this is what makes the volume AZ-independent and is the
# entire reason EFS was chosen over EBS. Do not reduce this to a single subnet.
#
# for_each iterates the STATIC CIDR local, not `module.vpc.private_subnets`. Keying on that output
# reads far more naturally and plans fine once the VPC exists -- which is exactly why it shipped --
# but on a from-scratch apply the subnet IDs do not exist yet, so Terraform cannot know the set of
# keys and fails the whole plan with "Invalid for_each argument". Only for_each VALUES may be unknown
# at plan time; keys may not. Hit for real on the 2026-08-05 rebuild, and the same trap ecr.tf:70
# records from 2026-07-30. Reverting this to `toset(module.vpc.private_subnets)` will pass every plan
# you run against a live VPC and break only the next rebuild from an empty state.
#
# Keys are AZ names ("il-central-1a"), so the resource addresses stay readable. The mount-target count
# tracks the subnet count by construction: this is the very list module.vpc turns into those subnets.
resource "aws_efs_mount_target" "jenkins" {
  for_each = {
    for idx, cidr in local.private_subnet_cidrs : var.azs[idx] => module.vpc.private_subnets[idx]
  }

  file_system_id  = aws_efs_file_system.jenkins.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

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

  # The mount targets must exist before the driver tries to use the filesystem.
  depends_on = [aws_efs_mount_target.jenkins]
}

resource "kubernetes_storage_class" "efs" {
  metadata { name = "efs-sc" }

  storage_provisioner = "efs.csi.aws.com"

  parameters = {
    provisioningMode = "efs-ap" # dynamic access points, one per PVC
    fileSystemId     = aws_efs_file_system.jenkins.id
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
