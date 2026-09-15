terraform {
  # 1.11 is the floor because backend.tf uses S3-native locking (use_lockfile), which replaced the
  # deprecated dynamodb_table argument. Adopting the deprecated path instead would only mean doing
  # this migration again later.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 6.0 since 2026-09-15, together with terraform-aws-modules/eks v21 (which requires it).
      # It was ~> 5.0 until then because eks v20 capped the provider at < 6.0.0. See
      # docs/design/2026-09-15-aws6-eks21-upgrade-design.md for what was pinned to avoid replacement.
      version = "~> 6.0"
    }
    helm = {
      source = "hashicorp/helm"
      # v3 moved this provider from SDKv2 to the Plugin Framework, which turned BLOCKS into
      # ATTRIBUTES: `kubernetes {}` -> `kubernetes = {}` in providers.tf, and every
      # `set {}` -> a `set = [{...}]` list on each helm_release. Both were converted on 2026-07-30.
      # Do not reintroduce block syntax; it fails validation against the v3 schema.
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12" # time_static: stable timestamp for the RDS final-snapshot name
    }
  }
}
