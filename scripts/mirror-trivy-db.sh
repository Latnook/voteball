#!/usr/bin/env bash
# Mirror Trivy's vulnerability database into this account's ECR.
#
# WHY: the EC2 build host kept a warm DB in a host mount (TRIVY_CACHE). Pod agents are destroyed
# after every build, so that mount has no equivalent -- and porting it to an emptyDir would silently
# turn a cross-build cache into a per-build one, re-downloading ~100MB on each of four scans, every
# build. That is exactly the ghcr.io rate-limit exposure the original mount existed to prevent.
#
# Mirroring instead is strictly better than the host cache: in-region, no rate limit, and no
# build-time dependency on a third-party host.
#
# Run this after a rebuild, and periodically (weekly is ample -- Trivy publishes every 6h, but a
# few-days-old DB only misses very recent CVEs). A STALE DB MAKES SCANS PASS THAT SHOULD FAIL:
# treat Trivy's stale-database warning in a build log as a build failure, not noise.
#
# skopeo is NOT installed on this machine (or expected to be, on whatever machine runs this), so it
# runs containerized via docker. Pinned to quay.io/skopeo/stable:v1.17.0 -- the exact version the
# Jenkins build pod template uses for the same tool (ci/jenkins/jenkins.yaml). Keeping the
# maintenance script and CI on one version means a skopeo behaviour change cannot affect one
# without the other.
#
# Requires: docker, aws CLI credentials for your account, and an applied terraform stack.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh

SKOPEO_IMAGE="quay.io/skopeo/stable:v1.17.0"

REGISTRY="$(tf_out ecr_registry)"
DEST="${REGISTRY}/${CLUSTER}-trivy-db"

# ghcr.io/aquasecurity/trivy-db is the OCI-packaged database Trivy pulls by default.
SRC="docker://ghcr.io/aquasecurity/trivy-db:2"
DST="docker://${DEST}:2"

echo "Mirroring Trivy DB -> ${DEST}"

# Credentials go in a temp authfile, never on the command line (which docker run would otherwise
# expose in `docker inspect`/`ps` to anyone with docker access). The authfile is written by a
# containerized `skopeo login` and read back by `skopeo copy --dest-authfile` from the same mounted
# directory -- each `docker run` is a fresh container, so nothing persists between them except what
# is on the mount.
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

skopeo() {
  docker run --rm -i \
    --user "$(id -u):$(id -g)" \
    -v "$TMP:/auth" \
    "$SKOPEO_IMAGE" "$@"
}

aws ecr get-login-password --region "$REGION" \
  | skopeo login --authfile /auth/auth.json --username AWS --password-stdin "$REGISTRY"

skopeo copy --dest-precompute-digests --dest-authfile /auth/auth.json "$SRC" "$DST"

echo "Done. Builds pull it via: trivy image --db-repository ${DEST}"
