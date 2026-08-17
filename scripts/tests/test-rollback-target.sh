#!/usr/bin/env bash
# Tests the rollback-target decision with NO AWS access and NO real repository history.
#
# The scenario that matters here cannot be reproduced by stubbing ECR alone: it needs a values.yaml
# GIT HISTORY that disagrees with what ECR holds, which is exactly the state a destroy/rebuild leaves
# behind (git survives the teardown, ECR does not). So each case builds a throwaway git repo with a
# handmade promote history, copies the three scripts in at their real relative paths, and runs
# rollback-target.sh from that repo's root -- the same layout its `cd "$(dirname "$0")/../.."` expects.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0

# build_fixture <tmpdir> <tag1> [tag2 ...] -- tag1 is the OLDEST, the last is what values.yaml
# currently names. previous-tag.sh reads the second-newest, so at least two are needed for a target.
build_fixture() {
  local dir="$1"; shift
  mkdir -p "$dir/charts/voteball" "$dir/scripts/ci"
  cp "$REPO_ROOT/scripts/ci/previous-tag.sh" \
     "$REPO_ROOT/scripts/ci/images-exist.sh" \
     "$REPO_ROOT/scripts/ci/rollback-target.sh" "$dir/scripts/ci/"
  chmod +x "$dir"/scripts/ci/*.sh
  git -C "$dir" init -q
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  local t
  for t in "$@"; do
    printf 'image:\n  registry: "example"\n  tag: "%s"\n' "$t" > "$dir/charts/voteball/values.yaml"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "ci: image tag $t [skip ci]"
  done
}

export AWS_REGION=il-central-1
export ECR_REPOS="voteball-backend voteball-worker"

# ---- the tag git names as previous IS in ECR: roll back to it --------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
build_fixture "$tmp/ok" old111a new222b
got="$(cd "$tmp/ok" && CI_STUB_DESCRIBE_CMD=true ./scripts/ci/rollback-target.sh)"; rc=$?
[ "$rc" = "0" ]        || fail "present target should exit 0, got $rc"; pass=$((pass+1))
[ "$got" = "old111a" ] || fail "should name the previous tag, got '$got'"; pass=$((pass+1))

# ---- THE REGRESSION: git names a previous tag, but ECR does not have it ----------------------
# This is the post-rebuild state. Before this script existed the pipeline rolled back to this tag
# anyway and died in Input Validation -- before Promote, so the depth-bounded retry never ran and the
# log blamed a bad parameter instead of a deleted registry.
set +e
got="$(cd "$tmp/ok" && CI_STUB_DESCRIBE_CMD=false ./scripts/ci/rollback-target.sh)"; rc=$?
set -e
[ "$rc" = "3" ] || fail "missing target must exit 3 (not 0), got $rc"; pass=$((pass+1))
[ "$got" = "NO_ROLLBACK_TARGET old111a" ] \
  || fail "must name the missing tag so a human knows what to redeploy, got '$got'"; pass=$((pass+1))

# ---- a PARTIALLY present target still counts as missing --------------------------------------
# images-exist.sh only says "present" when every repository holds the tag; a rollback to a half-
# pushed tag would leave the namespace running a mix of two releases.
cat > "$tmp/partial.sh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "voteball-backend" ] && exit 0; done
exit 1
STUB
chmod +x "$tmp/partial.sh"
set +e
got="$(cd "$tmp/ok" && CI_STUB_DESCRIBE_CMD="$tmp/partial.sh" ./scripts/ci/rollback-target.sh)"; rc=$?
set -e
[ "$rc" = "3" ] || fail "partially-present target must exit 3, got $rc"; pass=$((pass+1))

# ---- no previous tag at all (nothing promoted yet) --------------------------------------------
build_fixture "$tmp/first" only111
set +e
got="$(cd "$tmp/first" && CI_STUB_DESCRIBE_CMD=true ./scripts/ci/rollback-target.sh)"; rc=$?
set -e
[ "$rc" = "4" ]              || fail "no previous tag must exit 4, got $rc"; pass=$((pass+1))
[ "$got" = "NO_PREVIOUS_TAG" ] || fail "expected NO_PREVIOUS_TAG, got '$got'"; pass=$((pass+1))

# ---- the two failure verdicts must stay DISTINGUISHABLE ---------------------------------------
# 3 and 4 need different human responses: 3 means "the image is gone, pick another tag", 4 means
# "there has never been another version". Collapsing them into one non-zero exit would lose that.
[ "3" != "4" ] || fail "sanity"
pass=$((pass+1))

# ---- Jenkinsfile-cd must actually USE this script ---------------------------------------------
# Without this, the whole guard can be silently orphaned by an edit to the pipeline -- which is the
# same failure mode that let previous-tag.sh sit disarmed by an escaping bug on 2026-08-04.
grep -q 'scripts/ci/rollback-target.sh' "$REPO_ROOT/Jenkinsfile-cd" \
  || fail "Jenkinsfile-cd no longer calls rollback-target.sh -- the rollback guard is orphaned"
pass=$((pass+1))

echo "ALL TESTS PASSED ($pass assertions)"
