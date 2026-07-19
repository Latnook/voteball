# Rollup snapshots + nightly backups bucket. The worker writes snapshots/ (Plan 1 code, gated on
# S3_BUCKET), the backup CronJob writes backups/ (Plan 3) -- two prefixes, two IRSA roles (irsa.tf).
# Fully private; the app reaches it via IRSA, never public.
resource "aws_s3_bucket" "rollups" {
  bucket = "${var.cluster_name}-rollups-${data.aws_caller_identity.current.account_id}"
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
