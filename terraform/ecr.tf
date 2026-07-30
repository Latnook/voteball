# One repo per own-image. scan_on_push turns on ECR's built-in vulnerability scan (the rubric's
# "is the image scanned?" line). Untagged images expire after 14 days to bound storage cost.
locals {
  # jenkins is the CI controller image (plugins baked in, see ci/jenkins/Dockerfile). It belongs in
  # this immutable set like the others: its tag is a git SHA and must never be overwritten.
  ecr_repos = ["backend", "worker", "nginx", "backup", "jenkins"]
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
  for_each             = toset(["buildcache", "trivy-db"])
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
resource "aws_ecr_lifecycle_policy" "cache" {
  for_each   = aws_ecr_repository.cache
  repository = each.value.name

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
