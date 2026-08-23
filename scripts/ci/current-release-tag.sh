#!/usr/bin/env bash
# Print the image tag currently deployed -- i.e. the one charts/voteball/values.yaml names on the
# RELEASE branch.
#
# WHY THIS EXISTS. Since 2026-08-23 ArgoCD watches `release`, and the only way onto `release` is
# through application-cd. That closed the gap where a chart-only commit skipped CI (every gate is
# `changeset 'services/**'`) and was auto-synced straight to the cluster past manifest validation,
# the smoke test, the monitoring gate and rollback -- Task 4 review finding P2.
#
# Closing it creates a question the old design never had to answer: a chart-only commit is a new
# SHA, and no images were ever built or pushed for that SHA, so CD cannot be triggered with it --
# Input Validation would (correctly) refuse a tag that is not in ECR. What CD needs is "deploy the
# chart at THIS commit, with the images that are already running", which is the tag on `release`.
#
# A separate script rather than an inline `sed` in Jenkinsfile-ci, for the reason this repo keeps
# relearning: a quoting bug inside a Groovy triple-quoted string silently disarmed rollback for weeks
# in August 2026 (see previous-tag.sh's header), and the linter does not look inside `sh` bodies.
#
# Usage:  [REF=origin/release] [VALUES_FILE=...] current-release-tag.sh
# Exits 1 with a message on stderr if the ref, the file, or a QUOTED tag line is missing.
set -euo pipefail

REF="${REF:-origin/release}"
VALUES_FILE="${VALUES_FILE:-charts/voteball/values.yaml}"

git rev-parse --verify --quiet "${REF}" >/dev/null \
  || { echo "current-release-tag: ref '$REF' does not exist (has anything been promoted yet?)" >&2; exit 1; }

content="$(git show "${REF}:${VALUES_FILE}" 2>/dev/null)" \
  || { echo "current-release-tag: $VALUES_FILE does not exist at $REF" >&2; exit 1; }

# QUOTED only, matching scripts/ci/previous-tag.sh. An unquoted `tag: abc1234` is the exact shape the
# 2026-08-04 escaping bug produced, and accepting it here would let a malformed release branch look
# healthy. The capture stops at the first closing quote so a trailing comment is not swallowed.
tag="$(printf '%s\n' "$content" \
       | sed -nE 's/^  tag: "([^"]*)".*/\1/p' \
       | head -1)"

[ -n "$tag" ] || {
  echo "current-release-tag: no QUOTED '  tag: \"...\"' line in $VALUES_FILE at $REF." >&2
  echo "  An unquoted tag: line is the 2026-08-04 escaping bug's signature -- refusing to guess." >&2
  exit 1
}

printf '%s\n' "$tag"
