#!/usr/bin/env bash
# Build one commit on the `release` branch: the tree of a promoted `master` commit, with the image
# tag and the four image digests pinned in charts/voteball/values.yaml.
#
# WHY A RELEASE BRANCH AT ALL (2026-08-23, Task 4 review findings P1 and P2 -- full reasoning in
# docs/design/2026-08-23-release-branch-and-digest-design.md). `master` used to be both the branch
# humans push to and the branch ArgoCD deploys, which caused two separate defects with one root:
#
#   * application-cd had to push its promotion commit to the branch application-ci watches. A source
#     commit pushed while CI was busy could end up hidden behind that promotion commit and never get
#     built -- the real 2026-08-21 incident.
#   * every gate in Jenkinsfile-ci is `changeset 'services/**'`, so a chart-only commit skipped CI
#     entirely and ArgoCD's automated sync applied it directly, bypassing manifest validation, the
#     smoke test, the monitoring gate and rollback.
#
# With ArgoCD watching `release`, CD is the only writer of the deployed branch and there is no way to
# reach devops-app by pushing anywhere.
#
# WHY read-tree AND NOT merge. A merge conflicts on values.yaml's image block on EVERY promotion --
# release holds the old tag, master holds whatever was last synced -- and a CD stage that can stop for
# a conflict is a CD stage that will. `git read-tree -u --reset` makes the index and working tree
# identical to the promoted commit while leaving HEAD on release, so:
#   * no conflict is possible, ever;
#   * history stays append-only, so this never needs --force (the repo's no-force-push rule applies
#     to release too) and scripts/ci/previous-tag.sh keeps the history it reads to find a rollback
#     target;
#   * every release commit's tree is a real master tree plus the pins, so `git diff master release`
#     shows the image block and nothing else.
# It also handles DELETIONS correctly, which `git checkout <sha> -- .` does not: that leaves a file
# removed on master present on release forever.
#
# Usage:
#   SOURCE_SHA=<sha> TAG=<tag> [DIGESTS="name=sha256:... ..."] promote-to-release.sh
#
# DIGESTS is optional -- omitted, the digest map is left as it is on the promoted tree, and the chart
# falls back to the tag (see voteball.image in charts/voteball/templates/_helpers.tpl). Callers get it
# from scripts/ci/resolve-digests.sh.
#
# Environment overrides, all for the tests: RELEASE_BRANCH, REMOTE, VALUES_FILE, PROMOTE_NO_PUSH.
set -euo pipefail

: "${SOURCE_SHA:?SOURCE_SHA must be set (the master commit being promoted)}"
: "${TAG:?TAG must be set}"

RELEASE_BRANCH="${RELEASE_BRANCH:-release}"
REMOTE="${REMOTE:-origin}"
VALUES_FILE="${VALUES_FILE:-charts/voteball/values.yaml}"
DIGESTS="${DIGESTS:-}"

git rev-parse --verify --quiet "${SOURCE_SHA}^{commit}" >/dev/null \
  || { echo "promote-to-release: $SOURCE_SHA is not a commit in this repository" >&2; exit 1; }

git fetch --quiet "$REMOTE" "$RELEASE_BRANCH" 2>/dev/null || true

if git rev-parse --verify --quiet "${REMOTE}/${RELEASE_BRANCH}" >/dev/null; then
  git checkout -q -B "$RELEASE_BRANCH" "${REMOTE}/${RELEASE_BRANCH}"
  # Index + working tree := the promoted tree, HEAD still on release. This is the whole trick.
  git read-tree -u --reset "$SOURCE_SHA"
else
  # First ever release commit: branch straight off the promoted commit, so release and master share
  # history rather than release being an orphan nobody can diff against.
  echo "promote-to-release: ${REMOTE}/${RELEASE_BRANCH} does not exist yet -- creating it from $SOURCE_SHA"
  git checkout -q -B "$RELEASE_BRANCH" "$SOURCE_SHA"
fi

[ -f "$VALUES_FILE" ] || { echo "promote-to-release: $VALUES_FILE is missing from $SOURCE_SHA" >&2; exit 1; }

# Rewrite the tag and the digest map. awk, not sed: the digest keys sit at four-space indent and
# names like `backend` and `backup` appear at other indents elsewhere in this file, so the rewrite has
# to know it is inside the `  digests:` block rather than pattern-match a bare key.
TAG="$TAG" DIGESTS="$DIGESTS" awk '
  BEGIN {
    n = split(ENVIRON["DIGESTS"], pairs, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (pairs[i] == "") continue
      eq = index(pairs[i], "=")
      if (eq > 0) D[substr(pairs[i], 1, eq - 1)] = substr(pairs[i], eq + 1)
    }
    tag = ENVIRON["TAG"]
  }
  /^  tag: "/            { print "  tag: \"" tag "\""; next }
  /^  digests:[[:space:]]*$/ { indig = 1; print; next }
  indig && /^    [A-Za-z_][A-Za-z0-9_-]*:/ {
    key = $1; sub(/:$/, "", key)
    if (key in D) { print "    " key ": \"" D[key] "\""; next }
    print; next
  }
  indig && !/^    / && !/^[[:space:]]*$/ { indig = 0 }
  { print }
' "$VALUES_FILE" > "$VALUES_FILE.tmp"
mv "$VALUES_FILE.tmp" "$VALUES_FILE"

# Assert the rewrite LANDED rather than trusting an exit code -- awk exits 0 whether or not any rule
# fired. If the tag line's shape ever drifts (re-indented, unquoted) the file silently keeps its old
# tag, the commit below finds nothing to commit, ArgoCD syncs the unchanged old version, and Verify
# and Smoke Test both pass because that old version is healthy. A green build that deployed nothing.
grep -q "^  tag: \"${TAG}\"$" "$VALUES_FILE" || {
  echo "promote-to-release: $VALUES_FILE does not name $TAG, QUOTED, after the rewrite -- the" >&2
  echo "  tag: line's shape must have changed. Refusing to report success on an unrewritten file." >&2
  exit 1
}
for pair in $DIGESTS; do
  key="${pair%%=*}"; val="${pair#*=}"
  grep -q "^    ${key}: \"${val}\"$" "$VALUES_FILE" || {
    echo "promote-to-release: the digest for '$key' did not land in $VALUES_FILE -- expected" >&2
    echo "  '    $key: \"$val\"'. The digests: block's shape must have changed." >&2
    exit 1
  }
done

# ONLY the values file. NEVER `git add -A` -- that was the original, and it swept whatever untracked
# files the agent workspace happened to contain into the release commit. Live CD #1 on 2026-08-23
# committed `image-digests.tsv` (written by the Input Validation stage) onto `release`; CD #2 then
# died on `git checkout -B release` with "untracked working tree files would be overwritten", because
# the file now existed on BOTH sides. A stray build artifact on the deployed branch had made the
# branch un-promotable.
#
# Nothing else needs staging: `git read-tree -u --reset` above already set the index to the promoted
# tree, INCLUDING deletions. So the index is correct and values.yaml is the single intentional edit
# on top of it. Scoping the add also means the release branch can only ever be "a master tree plus
# the image pins", which is the property the whole design rests on.
git add "$VALUES_FILE"

if git diff --cached --quiet; then
  echo "promote-to-release: $RELEASE_BRANCH already matches $SOURCE_SHA at tag $TAG -- nothing to commit"
  git rev-parse HEAD
  exit 0
fi

git -c user.name="${GIT_AUTHOR_NAME:-jenkins}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-jenkins@voteball.local}" \
    commit -q -m "release: $(git rev-parse --short "$SOURCE_SHA") (image tag $TAG)"

if [ "${PROMOTE_NO_PUSH:-0}" != "1" ]; then
  git push -q "$REMOTE" "HEAD:${RELEASE_BRANCH}"
fi

git rev-parse HEAD
