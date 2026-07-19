#!/usr/bin/env sh
# Nightly backup: pg_dump the app DB and stream it (gzipped) straight to S3 under backups/.
# Creds come from env (ConfigMap + ESO Secret): DB_HOST/DB_NAME/DB_USER/DB_PASS, S3_BUCKET.
set -eu
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
KEY="backups/voteball-${TS}.sql.gz"
echo "Dumping ${DB_NAME}@${DB_HOST} -> s3://${S3_BUCKET}/${KEY}"
PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" --no-owner \
  | gzip \
  | aws s3 cp - "s3://${S3_BUCKET}/${KEY}" --content-type application/gzip
echo "Backup complete: ${KEY}"
