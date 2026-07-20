#!/usr/bin/env bash
# Sole writer of the environment-specific fields in charts/voteball/values.yaml.
#
# Every value below changes when the stack is rebuilt (new RDS instance, new ACM cert, new IAM roles),
# which is why hand-copying them kept breaking deploys. Run this instead of editing the file.
#
#   ./scripts/sync-values-from-tf.sh              # write current values (tag = git HEAD)
#   ./scripts/sync-values-from-tf.sh --check      # exit 1 if drifted, write nothing (preflight)
#   ./scripts/sync-values-from-tf.sh --tag abc123 # pin a specific image tag
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

. scripts/lib/config.sh
VALUES="charts/voteball/values.yaml"
CHECK_ONLY=0
TAG=""
TAG_EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  CHECK_ONLY=1; shift ;;
    --tag)    TAG="$2"; TAG_EXPLICIT=1; shift 2 ;;
    --values) VALUES="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TAG" ] || TAG="$(git rev-parse --short HEAD)"

# Read one Terraform output. SYNC_STUB_<name> overrides it, so the test suite can run with no AWS
# credentials and no built stack.
tf_output() {
  local name="$1" stub
  stub="SYNC_STUB_${name}"
  if [ -n "${!stub:-}" ]; then
    printf '%s' "${!stub}"
    return 0
  fi
  if ! terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null; then
    echo "ERROR: could not read Terraform output '${name}'." >&2
    echo "Is the stack applied? Try: terraform -chdir=${TF_DIR} output" >&2
    exit 1
  fi
}

DB_HOST="$(tf_output rds_endpoint)"
CERT_ARN="$(tf_output acm_certificate_arn)"
S3_BUCKET="$(tf_output s3_bucket)"
BACKUP_ROLE="$(tf_output backup_role_arn)"
WORKER_ROLE="$(tf_output worker_role_arn)"
REGISTRY="$(tf_output ecr_registry)"
APP_DOMAIN_V="$(tf_output app_domain)"
SNS_TOPIC="$(tf_output sns_topic_arn)"

# Section-aware rewrite. `roleArn` exists under BOTH `backup:` and `worker:` at the same indent, so a
# plain anchored sed would assign the same ARN to both. Track the current top-level section instead.
# Line-oriented (not a YAML round-trip) so comments and formatting survive byte-for-byte.
# In --check mode, image.tag is only compared when --tag was given explicitly. Comparing it to git
# HEAD by default would report drift after any commit that doesn't rebuild images (docs, terraform),
# and a preflight that cries wolf is a preflight people learn to ignore. The invariant that actually
# matters -- the tag names an image that exists in ECR -- is checked separately below.
if [ "$CHECK_ONLY" = "1" ] && [ "$TAG_EXPLICIT" = "0" ]; then
  CHECK_SKIP_TAG=1
else
  CHECK_SKIP_TAG=0
fi

CHECK_ONLY="$CHECK_ONLY" VALUES="$VALUES" TF_DIR="$TF_DIR" CHECK_SKIP_TAG="$CHECK_SKIP_TAG" \
TAG="$TAG" DB_HOST="$DB_HOST" CERT_ARN="$CERT_ARN" S3_BUCKET="$S3_BUCKET" \
BACKUP_ROLE="$BACKUP_ROLE" WORKER_ROLE="$WORKER_ROLE" \
REGISTRY="$REGISTRY" APP_DOMAIN_V="$APP_DOMAIN_V" SNS_TOPIC="$SNS_TOPIC" \
python3 <<'PY'
import os, re, sys

values_path = os.environ["VALUES"]
check_only  = os.environ["CHECK_ONLY"] == "1"

managed = {
    ("image",   "tag"):            os.environ["TAG"],
    ("config",  "DB_HOST"):        os.environ["DB_HOST"],
}
if os.environ.get("CHECK_SKIP_TAG") == "1":
    del managed[("image", "tag")]
managed.update({
    ("config",  "S3_BUCKET"):      os.environ["S3_BUCKET"],
    ("ingress", "certificateArn"): os.environ["CERT_ARN"],
    ("backup",  "roleArn"):        os.environ["BACKUP_ROLE"],
    ("worker",  "roleArn"):        os.environ["WORKER_ROLE"],
    ("image",   "registry"):       os.environ["REGISTRY"],
    ("ingress", "host"):           os.environ["APP_DOMAIN_V"],
    ("config",  "SNS_TOPIC"):      os.environ["SNS_TOPIC"],
})

top_re = re.compile(r'^([A-Za-z_][\w-]*):\s*$')
kv_re  = re.compile(r'^(  )([A-Za-z_][\w-]*): (")([^"]*)(")(.*)$')

with open(values_path) as fh:
    lines = fh.read().splitlines(keepends=True)

section = None
changed = []
out = []

for line in lines:
    m_top = top_re.match(line)
    if m_top:
        section = m_top.group(1)
        out.append(line)
        continue

    m_kv = kv_re.match(line)
    if m_kv and (section, m_kv.group(2)) in managed:
        want = managed[(section, m_kv.group(2))]
        have = m_kv.group(4)
        if have != want:
            changed.append(f"  {section}.{m_kv.group(2)}: {have} -> {want}")
            line = f"{m_kv.group(1)}{m_kv.group(2)}: \"{want}\"{m_kv.group(6)}\n"
    out.append(line)

found = set()
section = None
for line in lines:
    m_top = top_re.match(line)
    if m_top:
        section = m_top.group(1)
        continue
    m_kv = kv_re.match(line)
    if m_kv and (section, m_kv.group(2)) in managed:
        found.add((section, m_kv.group(2)))

missing = set(managed) - found
if missing:
    for s, k in sorted(missing):
        print(f"ERROR: expected key {s}.{k} not found in {values_path}", file=sys.stderr)
    print("The values file layout changed; update scripts/sync-values-from-tf.sh.", file=sys.stderr)
    sys.exit(2)

if check_only:
    if changed:
        print("values.yaml is OUT OF SYNC with the live stack:")
        print("\n".join(changed))
        print("\nRun: ./scripts/sync-values-from-tf.sh")
        sys.exit(1)
    print(f"values.yaml is in sync with {os.environ['TF_DIR']}.")
    sys.exit(0)

if not changed:
    print("values.yaml already in sync; nothing to write.")
    sys.exit(0)

with open(values_path, "w") as fh:
    fh.writelines(out)

print("Updated values.yaml:")
print("\n".join(changed))
PY

# The invariant image.tag must satisfy: the tag names an image that actually exists in ECR. A tag
# pointing at a never-pushed SHA is exactly the ImagePullBackOff that broke the 2026-07-20 deploy.
# Skipped when stubbed (tests run without AWS).
if [ "$CHECK_ONLY" = "1" ] && [ -z "${SYNC_STUB_rds_endpoint:-}" ]; then
  CURRENT_TAG="$(sed -n 's/^  tag: "\(.*\)".*/\1/p' "$VALUES" | head -1)"
  if ! aws ecr describe-images --repository-name "${CLUSTER}-backend" --region "$REGION" \
       --image-ids "imageTag=${CURRENT_TAG}" >/dev/null 2>&1; then
    echo "ERROR: image.tag \"${CURRENT_TAG}\" does not exist in ECR (${CLUSTER}-backend)." >&2
    echo "Build and push it first:  ./scripts/build-push-ecr.sh" >&2
    exit 1
  fi
  echo "image.tag \"${CURRENT_TAG}\" exists in ECR."
fi
