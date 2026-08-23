#!/usr/bin/env bash
# Regenerate ci/jenkins/plugins.lock.txt from ci/jenkins/plugins.txt, against the base image
# ci/jenkins/Dockerfile actually pins.
#
# WHY A LOCK EXISTS AT ALL (2026-08-23, Task 4 review finding P2): plugins.txt names no versions, so
# jenkins-plugin-cli resolved "latest compatible" at image-build time and rebuilding the same git
# commit later produced a different controller. The immutable ECR tag pinned what was DEPLOYED but
# not what a REBUILD would produce -- and the review found the drift already visible in this repo's
# evidence (Helm release app version 2.568.1 vs a controller inventory reporting 2.568.2).
#
# RUN THIS whenever you add or remove a plugin in plugins.txt, or bump the FROM line in the
# Dockerfile -- in the SAME commit as the change. Plugin resolution depends on the core version, so a
# new base image with an old lock is a combination nobody has ever booted.
# scripts/tests/test-jenkins-plugin-lock.sh fails the build if the two files disagree.
#
# Needs docker and network. It runs the pinned base image's own jenkins-plugin-cli rather than
# reimplementing dependency resolution -- the resolver IS the thing being captured.
set -euo pipefail

cd "$(dirname "$0")/../.."

PLUGINS="ci/jenkins/plugins.txt"
LOCK="ci/jenkins/plugins.lock.txt"
DOCKERFILE="ci/jenkins/Dockerfile"

command -v docker >/dev/null || { echo "docker is required to regenerate the plugin lock." >&2; exit 1; }
[ -f "$PLUGINS" ] || { echo "$PLUGINS is missing." >&2; exit 1; }

# Read the base image straight out of the Dockerfile, so the lock can never be generated against a
# different image than the one that will be built. Hardcoding it here is exactly the second source of
# truth this file exists to remove.
BASE="$(awk '/^FROM /{print $2; exit}' "$DOCKERFILE")"
[ -n "$BASE" ] || { echo "Could not read a FROM line out of $DOCKERFILE." >&2; exit 1; }
case "$BASE" in
  *@sha256:*) ;;
  *) echo "WARNING: $DOCKERFILE's base image is not digest-pinned ($BASE)." >&2
     echo "         The lock will be generated against whatever that tag means today, which is the" >&2
     echo "         reproducibility gap this file exists to close." >&2 ;;
esac

echo "Resolving plugins against $BASE ..."
raw="$(docker run --rm -v "$PWD/$PLUGINS:/plugins.txt:ro" --entrypoint sh "$BASE" \
        -c 'jenkins-plugin-cli --plugin-file /plugins.txt --list 2>/dev/null')"

resolved="$(printf '%s\n' "$raw" | grep -E '^[a-z0-9]' | sed 's/ /:/' | sort)"
count="$(printf '%s\n' "$resolved" | grep -c . || true)"
[ "${count:-0}" -gt 10 ] || {
  echo "Only ${count:-0} plugins resolved -- that is not a plausible closure for $PLUGINS." >&2
  echo "Refusing to overwrite $LOCK with it. Raw output was:" >&2
  printf '%s\n' "$raw" | head -20 >&2
  exit 1
}

{
  # Everything above the generation stamp is prose and is preserved verbatim, so the explanation of
  # why this file exists is not rewritten (or lost) on every regeneration.
  if [ -f "$LOCK" ]; then
    sed -n '1,/^# this file drifts from plugins.txt/p' "$LOCK"
  fi
  printf '#\n# Generated %s against %s\n#\n' "$(date +%Y-%m-%d)" "$BASE"
  printf '%s\n' "$resolved"
} > "$LOCK.tmp"
mv "$LOCK.tmp" "$LOCK"

echo "Wrote $LOCK ($count plugins)."
echo "Commit it together with the change that prompted it."
