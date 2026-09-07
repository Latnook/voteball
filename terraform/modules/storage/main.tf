# Rollup snapshots + nightly backups bucket. The worker writes snapshots/ (Plan 1 code, gated on
# S3_BUCKET), the backup CronJob writes backups/ (Plan 3) -- two prefixes, two IRSA roles (modules/iam).
# Fully private; the app reaches it via IRSA, never public.
resource "aws_s3_bucket" "rollups" {
  bucket = "${var.cluster_name}-rollups-${var.account_id}"

  # Demo bucket: let `terraform destroy` empty it (incl. all object versions) instead of failing on a
  # non-empty versioned bucket. Snapshots/backups here are disposable (the RDS snapshot is the record).
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "rollups" {
  bucket                  = aws_s3_bucket.rollups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "rollups" {
  bucket = aws_s3_bucket.rollups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# One repo per own-image. scan_on_push turns on ECR's built-in vulnerability scan (the rubric's
# "is the image scanned?" line). Untagged images expire after 14 days to bound storage cost.
locals {
  # jenkins is the CI controller image (plugins baked in, see ci/jenkins/Dockerfile). It belongs in
  # this immutable set like the others: its tag is a git SHA and must never be overwritten.
  ecr_repos = ["backend", "worker", "nginx", "backup", "jenkins"]

  # Cache repositories, deliberately SEPARATE from ecr_repos above: these are MUTABLE, those are
  # IMMUTABLE. Kept as its own local so the lifecycle policy below can key off a statically known
  # list rather than off the repository resource -- see the comment on aws_ecr_lifecycle_policy.cache.
  ecr_cache_repos = ["buildcache", "trivy-db"]
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(local.ecr_repos)
  name                 = "${var.cluster_name}-${each.key}"
  image_tag_mutability = "IMMUTABLE" # git-SHA tags are unique; immutability prevents silent overwrite
  force_delete         = true        # let `terraform destroy` remove repos that still hold images (images rebuild from git)

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

# ---- Build caches. MUTABLE ON PURPOSE, and deliberately NOT in local.ecr_repos. ----
#
# Every repo above is IMMUTABLE because a git-SHA tag is unique and must never be silently
# overwritten. Cache tags are the exact opposite: they are REWRITTEN on every build by design.
# Adding either repo below to local.ecr_repos makes every build fail on cache export with
# "cannot overwrite immutable tag", and the error surfaces at the end of a long build.
#
# buildcache: BuildKit layer cache (--export-cache/--import-cache type=registry).
# trivy-db:   a mirror of Trivy's vulnerability database, so scans do not pull from ghcr.io on every
#             build. Replaces the TRIVY_CACHE host mount the EC2 host used; a pod volume could not
#             do this job because it dies with the build. See the design doc section 5a.
resource "aws_ecr_repository" "cache" {
  for_each             = toset(local.ecr_cache_repos)
  name                 = "${var.cluster_name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    # These hold cache blobs and a vulnerability database, not deployable images. Scanning them
    # produces noise about a scanner's own contents.
    scan_on_push = false
  }
}

# Cache grows without bound otherwise: every build writes new layer blobs and orphans the old ones.
#
# for_each iterates the STATIC local, not `aws_ecr_repository.cache`. Iterating the resource reads
# naturally and plans fine once the repos exist -- but before they do, their map keys are unknown, and
# `terraform import` of ANY resource in this stack then fails with "Invalid for_each argument" because
# it must evaluate the whole config graph. Hit for real on 2026-07-30, mid-migration, blocking an
# unrelated secret import. The `app` policy above still iterates its resource; it survives only
# because those repositories are already in state.
resource "aws_ecr_lifecycle_policy" "cache" {
  for_each   = toset(local.ecr_cache_repos)
  repository = aws_ecr_repository.cache[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire cache blobs after 14 days"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

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
  vpc_id      = var.vpc_id

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
  referenced_security_group_id = var.node_security_group_id
}

# One mount target per private subnet -- this is what makes the volume AZ-independent and is the
# entire reason EFS was chosen over EBS. Do not reduce this to a single subnet.
#
# for_each iterates var.private_subnet_cidrs, the STATIC list handed in from the root, NOT
# var.private_subnet_ids (which the VPC module produces). Keying on the subnet ids reads far more
# naturally and plans fine once the VPC exists -- which is exactly why it shipped that way -- but on
# a from-scratch apply those ids do not exist yet, so Terraform cannot know the set of KEYS and fails
# the whole plan with "Invalid for_each argument". Only for_each VALUES may be unknown at plan time;
# keys may not. That is why both lists are passed in separately, and why the ids appear only on the
# value side below. Hit for real on the 2026-08-05 rebuild, and the same trap
# aws_ecr_lifecycle_policy.cache above records from 2026-07-30.
#
# Keys are AZ names ("il-central-1a"), so the resource addresses stay readable. The mount-target count
# tracks the subnet count by construction: this is the very list the VPC module turns into subnets.
resource "aws_efs_mount_target" "jenkins" {
  for_each = {
    for idx, cidr in var.private_subnet_cidrs : var.azs[idx] => var.private_subnet_ids[idx]
  }

  file_system_id  = aws_efs_file_system.jenkins.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}
