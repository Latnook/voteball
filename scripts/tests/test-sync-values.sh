#!/usr/bin/env bash
# Tests the section-aware rewriter against a fixture, with NO AWS/Terraform access.
# Terraform lookups are stubbed via the SYNC_STUB_* env vars the script honours.
set -euo pipefail
cd "$(dirname "$0")/../.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/values.yaml"

cat > "$FIXTURE" <<'EOF'
image:
  registry: "old.dkr.ecr.example.com"
  tag: "OLDTAG" # git-SHA tag
  pullPolicy: IfNotPresent

config:
  DB_HOST: "old-db.example.com"
  DB_NAME: "postgres"
  S3_BUCKET: "old-bucket"
  SNS_TOPIC: "arn:aws:sns:old"

ingress:
  host: "voteball.latnook.com"
  certificateArn: "arn:aws:acm:il-central-1:590183895228:certificate/OLD"
  wafAclArn: "arn:aws:wafv2:il-central-1:590183895228:regional/webacl/OLD/OLD"

backup:
  roleArn: "arn:aws:iam::590183895228:role/OLD-backup"
  schedule: "0 2 * * *"

worker:
  replicas: 1
  roleArn: "arn:aws:iam::590183895228:role/OLD-worker"
EOF

export SYNC_STUB_rds_endpoint="new-db.example.com"
export SYNC_STUB_acm_certificate_arn="arn:aws:acm:il-central-1:590183895228:certificate/NEW"
export SYNC_STUB_s3_bucket="new-bucket"
export SYNC_STUB_backup_role_arn="arn:aws:iam::590183895228:role/NEW-backup"
export SYNC_STUB_worker_role_arn="arn:aws:iam::590183895228:role/NEW-worker"
export SYNC_STUB_ecr_registry="new.dkr.ecr.example.com"
export SYNC_STUB_app_domain="new.example.com"
export SYNC_STUB_sns_topic_arn="arn:aws:sns:NEWTOPIC"
export SYNC_STUB_waf_web_acl_arn="arn:aws:wafv2:il-central-1:590183895228:regional/webacl/NEWACL/abc"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- 1. --check on a drifted file must exit non-zero and NOT write ---
BEFORE="$(cat "$FIXTURE")"
if ./scripts/sync-values-from-tf.sh --check --tag NEWTAG --values "$FIXTURE"; then
  fail "--check should exit non-zero when the file has drifted"
fi
[ "$BEFORE" = "$(cat "$FIXTURE")" ] || fail "--check must not modify the file"

# --- 2. a real run rewrites every managed value ---
./scripts/sync-values-from-tf.sh --tag NEWTAG --values "$FIXTURE"

grep -q 'tag: "NEWTAG"' "$FIXTURE" || fail "image.tag not updated"

# The INVERSE assertions, and they are the point of this block since 2026-09-08. Those nine fields
# moved into the ArgoCD Application's helm.parameters so this account's ARNs stop being committed to
# a public repo, and this script must now leave them ALONE. Asserting "still old" rather than
# "updated" is what catches someone re-adding one to the `managed` dict -- which would silently
# reintroduce the leak, since a committed real value looks exactly like a correct one.
# See docs/design/2026-09-08-argocd-helm-parameters-design.md.
grep -q 'DB_HOST: "old-db.example.com"' "$FIXTURE" || fail "config.DB_HOST was rewritten; it belongs to the ArgoCD Application now"
grep -q 'S3_BUCKET: "old-bucket"'       "$FIXTURE" || fail "config.S3_BUCKET was rewritten; it belongs to the ArgoCD Application now"
grep -q 'SNS_TOPIC: "arn:aws:sns:old"'  "$FIXTURE" || fail "config.SNS_TOPIC was rewritten; it belongs to the ArgoCD Application now"

# And the REAL values.yaml must never carry one. This is the check that would have caught the
# original problem: it reads the actual chart file, not a fixture.
#
# The working tree, deliberately, not `git show HEAD:` -- in CI the working tree IS the commit under
# test, and reading HEAD would lag by one commit and reject the very commit that removes a leak.
REAL_VALUES="$(cat charts/voteball/values.yaml)"
for field in DB_HOST S3_BUCKET SNS_TOPIC certificateArn wafAclArn roleArn host; do
  if printf '%s' "$REAL_VALUES" | grep -E "^\\s*${field}: " | grep -qE 'arn:aws|amazonaws\\.com|[0-9]{12}'; then
    fail "committed values.yaml carries a real value for ${field} -- it belongs in the ArgoCD Application"
  fi
done

# wafAclArn and certificateArn are both ARNs under `ingress:` -- a naive rewrite that matched on
# value shape rather than key name would swap them, which fails at deploy time with an unhelpful
# error from the load balancer controller rather than here.
grep -q 'certificateArn: "arn:aws:acm:' "$FIXTURE" || fail "certificateArn overwritten with the wrong ARN"
grep -q 'wafAclArn: "arn:aws:wafv2:'    "$FIXTURE" || fail "wafAclArn overwritten with the wrong ARN"

# --- 3. the two same-named roleArn keys must be left ALONE ---
#
# This block used to assert the opposite: that a naive anchored sed had not cross-assigned the backup
# ARN to the worker service account, since `roleArn` appears under BOTH `backup:` and `worker:` at
# the same indent. That hazard is gone by construction -- since 2026-09-08 this script does not write
# either one, and the ArgoCD Application addresses them as `backup.roleArn` and `worker.roleArn`,
# which are distinct parameter names that cannot collide the way two identical YAML keys could.
#
# Kept, inverted, rather than deleted: the section-aware rewriter is still in the script, so if a
# field with a duplicated key name is ever added back to `managed`, this is where it gets caught.
grep -q 'roleArn: "arn:aws:iam::590183895228:role/OLD-backup"' "$FIXTURE" || fail "backup.roleArn was rewritten; it belongs to the ArgoCD Application now"
grep -q 'roleArn: "arn:aws:iam::590183895228:role/OLD-worker"' "$FIXTURE" || fail "worker.roleArn was rewritten; it belongs to the ArgoCD Application now"
[ "$(grep -c 'NEW-backup' "$FIXTURE")" -eq 0 ] || fail "the script wrote a roleArn at all; it no longer manages either"
[ "$(grep -c 'NEW-worker' "$FIXTURE")" -eq 0 ] || fail "the script wrote a roleArn at all; it no longer manages either"

# --- 4. unmanaged keys and comments survive ---
grep -q 'DB_NAME: "postgres"'   "$FIXTURE" || fail "unmanaged key DB_NAME was clobbered"
grep -q 'schedule: "0 2 \* \* \*"' "$FIXTURE" || fail "unmanaged key schedule was clobbered"
grep -q '# git-SHA tag'         "$FIXTURE" || fail "trailing comment was lost"

# --- 5. --check on a synced file exits 0 ---
./scripts/sync-values-from-tf.sh --check --tag NEWTAG --values "$FIXTURE" \
  || fail "--check should exit 0 when the file is already in sync"

# --- 6. an UNQUOTED tag line must be detected, not silently accepted ---
# Regression test for the Jenkinsfile-cd Promote-stage quoting bug fixed 2026-08-04 (a Groovy
# ''' string escaping mistake made the CD pipeline write `tag: <sha>` with no quotes on every
# deploy). This script's own scaffold above is hand-written WITH quotes, so it never exercised
# this shape and the bug shipped to production undetected. `kv_re` only matches a QUOTED
# `  key: "value"` line, so an unquoted `tag:` line is invisible to it -- the key is then reported
# "not found" rather than silently left alone or, worse, treated as already-synced.
# Built from scratch, not derived from $FIXTURE -- by this point in the script $FIXTURE has
# already been rewritten to NEWTAG by test 2 above, so a sed derived from it would not contain
# OLDTAG to unquote.
UNQUOTED="$TMP/values-unquoted.yaml"
cat > "$UNQUOTED" <<'EOF'
image:
  registry: "old.dkr.ecr.example.com"
  tag: OLDTAG # git-SHA tag
  pullPolicy: IfNotPresent

config:
  DB_HOST: "old-db.example.com"
  DB_NAME: "postgres"
  S3_BUCKET: "old-bucket"
  SNS_TOPIC: "arn:aws:sns:old"

ingress:
  host: "voteball.latnook.com"
  certificateArn: "arn:aws:acm:il-central-1:590183895228:certificate/OLD"
  wafAclArn: "arn:aws:wafv2:il-central-1:590183895228:regional/webacl/OLD/OLD"

backup:
  roleArn: "arn:aws:iam::590183895228:role/OLD-backup"
  schedule: "0 2 * * *"

worker:
  replicas: 1
  roleArn: "arn:aws:iam::590183895228:role/OLD-worker"
EOF
grep -q '^  tag: OLDTAG' "$UNQUOTED" || fail "test setup: fixture copy does not have an unquoted tag line"

if ./scripts/sync-values-from-tf.sh --tag NEWTAG --values "$UNQUOTED" 2>/tmp/unquoted-sync.err; then
  fail "sync-values-from-tf.sh must refuse to run against an unquoted tag: line, not exit 0"
fi
grep -q 'expected key image.tag not found' /tmp/unquoted-sync.err \
  || fail "unquoted tag: line was not detected as a missing/malformed key (got: $(cat /tmp/unquoted-sync.err))"
grep -q '^  tag: OLDTAG' "$UNQUOTED" \
  || fail "an unquoted tag: line must be left untouched on refusal, not silently rewritten"
rm -f /tmp/unquoted-sync.err

echo "PASS: all sync-values assertions"
