#!/usr/bin/env bash
# Build the four app images and push them to ECR with a git-SHA tag.
# Pass "jenkins" as the sole argument to instead build the Jenkins controller image
# (ci/jenkins) into ${CLUSTER}-jenkins -- not part of the per-commit pipeline, so it is a
# separate, by-hand target rather than a fifth entry below.
#
# "jenkins" takes an optional second argument: the tag to push under. Default is the current
# git SHA, matching the normal by-hand workflow (build, note the SHA, hand-bump
# jenkins_image_tag in voteball.tfvars to match). deploy.sh's fresh-rebuild step instead PASSES
# the tag already pinned in voteball.tfvars, so it reproduces that exact image under that exact
# tag with no tfvars edit needed -- required because ECR repos are force_delete'd on destroy, so
# a fresh rebuild's helm_release.jenkins has nothing to pull otherwise (see deploy.sh step 2).
#
# Requires: docker, aws CLI credentials for your account, and an applied terraform stack.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

. scripts/lib/config.sh
TAG="$(git rev-parse --short HEAD)"

# --- BEGIN dirty-tree guard ---
# Images are tagged with the git SHA, so building from a working tree that does not match HEAD
# publishes an image whose tag lies about its contents -- and NOTHING downstream catches it.
# ArgoCD syncs it, the smoke test passes, and CD's `ci: image tag <sha>` commit records the wrong
# provenance permanently. Hit for real on 2026-08-11: revision 18's seed.sql was uncommitted while
# deploy.sh reached this script, which would have shipped it as `b9e3054` -- a commit that does not
# contain it.
#
# This runs before the ECR login on purpose, so it needs no AWS credentials and costs nothing. It
# also means deploy.sh fails at step 5 (the Jenkins image), which is BEFORE the billed apply at
# step 6 -- the same reason the credential preflight sits at the top of that script.
#
# Untracked files count: they are not in HEAD but docker build DOES put them in the build context,
# so they can reach the image. Gitignored files are excluded by git status and cannot.
#
# terraform/.terraform.lock.hcl is the ONE exemption, and it is here because the deploy dirties its
# own tree: deploy.sh step 2 runs `terraform init -upgrade`, which rewrites that file whenever a
# provider has a newer version (hashicorp/tls 4.3.0 -> 4.4.0 on 2026-09-02), and step 5 then
# refuses to build -- killing the deploy ~4 minutes in and forcing a manual commit plus a restart
# from step 1. The exemption is safe for one specific reason, and it is the only reason: the docker
# build contexts are services/{backend,worker,frontend,backup}/ and ci/jenkins/, so this file is in
# none of them and cannot change a byte of any image. It therefore cannot produce the lying tag
# this guard exists to prevent. Do NOT widen it to terraform/ as a whole -- nothing else here has
# that property established, and the guard's value is that its exceptions are argued individually.
#
# Filtered with a git PATHSPEC rather than a grep over the output: git does the matching, so a path
# containing a space, or a rename's ` -> ` arrow, cannot slip past a regex. `top` makes the path
# repo-root-relative regardless of the caller's working directory.
DIRTY="$(git status --porcelain -- ':/' ':(exclude,top)terraform/.terraform.lock.hcl')"
if [ -n "$DIRTY" ]; then
  if [ "${ALLOW_DIRTY_BUILD:-}" = "1" ]; then
    TAG="${TAG}-dirty"
    echo "WARNING: working tree is dirty -- tagging ${TAG} so the tag cannot claim to be a commit." >&2
    echo "         (An explicit tag argument, e.g. deploy.sh's pinned jenkins tag, is NOT suffixed" >&2
    echo "          and remains the caller's responsibility.)" >&2
  else
    echo "ERROR: refusing to build -- the working tree has uncommitted changes." >&2
    echo "       Images are tagged '${TAG}' from git, so this build would publish an image whose" >&2
    echo "       tag does not describe its contents, and no later stage would notice." >&2
    echo "       Commit or stash first, or re-run with ALLOW_DIRTY_BUILD=1 to tag '${TAG}-dirty'." >&2
    printf '%s\n' "$DIRTY" >&2
    exit 1
  fi
fi
# --- END dirty-tree guard ---

REGISTRY="$(tf_out ecr_registry)"

echo "Logging in to ECR ${REGISTRY}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() {
  local repo="$1" ctx="$2" tag="${3:-$TAG}"
  # These repos are IMMUTABLE (terraform/ecr.tf), so re-pushing an existing tag is REJECTED by the
  # registry -- and under `set -e` that failure aborts whatever called us. deploy.sh is the caller
  # that matters: if it dies anywhere after an image push (observed 2026-08-03, when the full apply
  # lost a race with EKS access-entry propagation), re-running it hit "tag already exists" at the
  # image step and could never get back to the apply. The environment has to be re-runnable, so
  # skip what is already there. Reuses CI's G1 check rather than a second copy of the same lookup.
  #
  # Skipping is correct, not a shortcut: tags here are either a git SHA (same SHA == same source)
  # or the tag pinned in voteball.tfvars. To genuinely replace an image, change the tag.
  if [ "$(ECR_REPOS="$repo" TAG="$tag" AWS_REGION="$REGION" scripts/ci/images-exist.sh)" = "present" ]; then
    echo "==> ${repo}:${tag} already in ECR -- skipping build and push"
    return 0
  fi
  echo "==> ${repo}:${tag}"
  docker build -t "${REGISTRY}/${repo}:${tag}" "$ctx"
  docker push "${REGISTRY}/${repo}:${tag}"
}

if [ "${1:-}" = "jenkins" ]; then
  JTAG="${2:-$TAG}"
  build_push "${CLUSTER}-jenkins" ci/jenkins "$JTAG"
  echo
  echo "Pushed jenkins image at tag: ${JTAG}"
  exit 0
fi

build_push "${CLUSTER}-backend" services/backend
build_push "${CLUSTER}-worker"  services/worker
build_push "${CLUSTER}-nginx"   services/frontend
build_push "${CLUSTER}-backup"  services/backup

echo
echo "Pushed all images at tag: ${TAG}"
echo "Run ./scripts/sync-values-from-tf.sh to pin it in charts/voteball/values.yaml"
