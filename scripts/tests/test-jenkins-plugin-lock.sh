#!/usr/bin/env bash
# Keeps ci/jenkins/plugins.txt, ci/jenkins/plugins.lock.txt and ci/jenkins/Dockerfile in step.
#
# The lock only buys reproducibility while it actually describes the declared plugin set built
# against the pinned base. Three ways that silently stops being true, all of which leave a GREEN
# build and a controller nobody can rebuild:
#   * a plugin is added to plugins.txt and the lock is not regenerated -- the image is built from the
#     lock, so the new plugin is simply absent, and the symptom is a pipeline step failing with
#     NoSuchMethodError rather than anything naming the plugin;
#   * the Dockerfile's FROM is bumped and the lock is not -- a core version and a plugin closure that
#     were never resolved together;
#   * the FROM loses its digest and quietly floats again, which is the exact state finding P2 was
#     about.
#
# Offline: compares files, never resolves anything. Regenerating needs docker and network
# (./scripts/jenkins/lock-plugins.sh); checking must not.
set -uo pipefail

cd "$(dirname "$0")/../.."

PLUGINS="ci/jenkins/plugins.txt"
LOCK="ci/jenkins/plugins.lock.txt"
DOCKERFILE="ci/jenkins/Dockerfile"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; pass=$((pass+1)); }

for f in "$PLUGINS" "$LOCK" "$DOCKERFILE"; do
  [ -f "$f" ] || fail "$f is missing"
done
ok "plugins.txt, plugins.lock.txt and the Dockerfile all exist"

# ---- 1. the base image is pinned by digest ------------------------------------------------------
base="$(awk '/^FROM /{print $2; exit}' "$DOCKERFILE")"
[ -n "$base" ] || fail "no FROM line in $DOCKERFILE"
case "$base" in
  *@sha256:*) ;;
  *) fail "$DOCKERFILE's base image ($base) is not digest-pinned. A moving tag means rebuilding this commit produces a different controller -- Task 4 review finding P2. Pin it and regenerate the lock with ./scripts/jenkins/lock-plugins.sh." ;;
esac
ok "the controller base image is pinned by digest"

# ...and by a readable version too. A bare digest pin is reproducible but tells nobody how stale it
# is, which is how a pin becomes a permanent one.
case "$base" in
  jenkins/jenkins:[0-9]*@sha256:*) ;;
  *) fail "$DOCKERFILE's base ($base) should name a VERSION as well as a digest, e.g. jenkins/jenkins:2.568.2-jdk21@sha256:... -- a bare digest gives no signal about how far behind it is." ;;
esac
ok "the base image also names a readable version, not just a digest"

# ---- 2. the Dockerfile installs the LOCK, not the unversioned list ------------------------------
grep -qE 'jenkins-plugin-cli --plugin-file [^ ]*plugins\.lock\.txt' "$DOCKERFILE" \
  || fail "$DOCKERFILE must install from plugins.lock.txt. Installing plugins.txt re-resolves 'latest compatible' at build time, which is the whole problem the lock exists to solve."
ok "the Dockerfile installs from plugins.lock.txt"

# ---- 3. the lock records which base it was generated against ------------------------------------
grep -q "^# Generated .* against ${base}$" "$LOCK" \
  || fail "$LOCK was not generated against the base the Dockerfile now pins ($base). Run ./scripts/jenkins/lock-plugins.sh and commit the result with the FROM change."
ok "the lock was generated against the base image the Dockerfile pins"

# ---- 4. every declared plugin appears in the lock -----------------------------------------------
declared="$(grep -vE '^\s*(#|$)' "$PLUGINS" | sed 's/[[:space:]]*$//' | cut -d: -f1 | sort -u)"
locked="$(grep -E '^[a-z0-9]' "$LOCK" | cut -d: -f1 | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$locked"))"
[ -z "$missing" ] || fail "declared in $PLUGINS but absent from $LOCK: $(printf '%s' "$missing" | tr '\n' ' ') -- the image installs the lock, so these plugins would NOT be installed. Run ./scripts/jenkins/lock-plugins.sh."
ok "every plugin declared in plugins.txt is present in the lock ($(printf '%s\n' "$declared" | grep -c .) declared)"

# ---- 5. the lock is a closure, not a copy -------------------------------------------------------
# If the two files had the same size the lock would not be recording transitive dependencies at all,
# which is the case where someone has "regenerated" it by copying.
n_dec="$(printf '%s\n' "$declared" | grep -c .)"
n_lock="$(printf '%s\n' "$locked" | grep -c .)"
[ "$n_lock" -gt "$n_dec" ] || fail "the lock ($n_lock) is not larger than the declared set ($n_dec) -- it should contain transitive dependencies, so it looks like a copy rather than a resolved closure."
ok "the lock is a resolved closure ($n_lock plugins from $n_dec declared)"

# ---- 6. every locked entry carries an exact version ---------------------------------------------
unversioned="$(grep -E '^[a-z0-9]' "$LOCK" | grep -vE '^[A-Za-z0-9._-]+:[^[:space:]]+$' || true)"
[ -z "$unversioned" ] || fail "these lock entries carry no version: $unversioned"
ok "every lock entry is name:version"

# ---- 7. plugins the pipeline CALLS BY NAME must be declared, not merely inherited ----------------
# junit is the case that prompted this: it was present only as a transitive dependency of
# workflow-aggregator, so Jenkinsfile-ci could not use the `junit` step without gambling that an
# unrelated dependency keeps pulling it in.
for needed in junit configuration-as-code job-dsl kubernetes prometheus; do
  grep -qxE "[[:space:]]*${needed}" "$PLUGINS" \
    || fail "'$needed' is used by this project's configuration or pipelines but is not DECLARED in $PLUGINS. Relying on it arriving transitively means it disappears the day an unrelated dependency drops it."
  pass=$((pass+1))
done
ok "plugins the pipelines and JCasC call by name are declared, not inherited"

echo "PASS: $(basename "$0") -- $pass checks"
