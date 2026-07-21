# Remote state for the main stack.
#
# The bucket, key and region are DELIBERATELY absent here: a `backend` block cannot interpolate
# variables (it is evaluated before the rest of the configuration exists), and the bucket name
# contains the AWS account id, which must never be committed. They come from backend.hcl instead --
# generated, gitignored, and written by scripts/bootstrap-tf-backend.sh:
#
#     ./scripts/bootstrap-tf-backend.sh
#     terraform -chdir=terraform init -backend-config=backend.hcl
#
# An `init` without -backend-config fails on incomplete backend configuration rather than silently
# falling back to local state, which is the correct failure direction.
#
# See docs/design/2026-07-21-terraform-remote-state-design.md.
terraform {
  backend "s3" {
    # S3-native locking (Terraform >= 1.11). The dynamodb_table argument every older tutorial shows
    # is deprecated; this holds the lock as an S3 object via conditional writes, so there is no
    # DynamoDB table to create, pay for, or migrate off later.
    use_lockfile = true
    encrypt      = true
  }
}
