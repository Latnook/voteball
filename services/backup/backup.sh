#!/usr/bin/env sh
# Nightly backup: pg_dump the app DB, gzip it, and upload to S3 under backups/.
# Creds come from env (ConfigMap + ESO Secret): DB_HOST/DB_NAME/DB_USER/DB_PASS, S3_BUCKET.
set -eu
# pipefail is REQUIRED, not tidiness. A pipeline's status is its LAST command, so without it a failed
# pg_dump still gzips to a valid ~20-byte empty archive, whatever consumes it exits 0, `set -e` never
# fires, and the Job is marked Complete -- a green backup containing nothing, with the BackupJobFailed
# alert silent. Not POSIX, but this runs on Alpine's BusyBox ash, which supports it.
set -o pipefail

# AWS CLI v2 pages output when stdout is a terminal. This normally runs as a CronJob (never a
# terminal), but it is also the script someone runs by hand inside the pod to take an ad-hoc backup,
# and there stdout IS a terminal. See scripts/lib/config.sh for the full reasoning; this script
# cannot source it (different image, no repo checkout).
export AWS_PAGER=""

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
KEY="backups/voteball-${TS}.sql.gz"
DUMP="/tmp/voteball-${TS}.sql.gz"
echo "Dumping ${DB_NAME}@${DB_HOST} -> s3://${S3_BUCKET}/${KEY}"

# Stage to the /tmp emptyDir FIRST, then upload -- do not pipe pg_dump straight into `aws s3 cp`.
# The backup role is deliberately write-only (s3:PutObject on backups/*, no s3:DeleteObject), so an
# object written by a half-finished dump can never be cleaned up by this job: it would sit in
# backups/ looking like a valid nightly backup forever. Staging locally means S3 only ever receives
# a dump that pg_dump exited 0 on. The cost is needing the dump on disk (see the emptyDir sizeLimit
# in backup-cronjob.yaml) instead of streaming it in constant space.
PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" --no-owner | gzip >"$DUMP"

# Catch a dump truncated by a mid-stream disconnect, which can still leave pg_dump exiting 0.
gzip -t "$DUMP"
gzip -dc "$DUMP" | tail -5 | grep -q 'PostgreSQL database dump complete' || {
  echo "Backup FAILED -- dump is missing pg_dump's completion trailer, refusing to upload" >&2
  exit 1
}

aws s3 cp "$DUMP" "s3://${S3_BUCKET}/${KEY}" --content-type application/gzip
echo "Backup complete: ${KEY} ($(wc -c <"$DUMP") bytes)"
