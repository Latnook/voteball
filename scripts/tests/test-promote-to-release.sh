#!/usr/bin/env bash
# Offline test for scripts/ci/promote-to-release.sh, against throwaway git repositories.
#
# Needs real git and cannot be stubbed: the properties under test ARE git behaviours -- that the
# release tree equals a master tree, that a file deleted on master disappears from release, that
# history stays append-only so no --force is ever needed. Asserting those against a fake would assert
# nothing. Same reasoning as test-rollback-target.sh, and the same group.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/ci/promote-to-release.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; pass=$((pass+1)); }

VALUES_REL="charts/voteball/values.yaml"

write_values() {   # write_values <tag>
  mkdir -p charts/voteball
  cat > "$VALUES_REL" <<YAML
image:
  registry: "example.dkr.ecr.eu-west-1.amazonaws.com"
  tag: "$1"
  pullPolicy: IfNotPresent
  digests:
    backend: ""
    worker: ""
    nginx: ""
    backup: ""
config:
  DB_NAME: "postgres"
backup:
  roleArn: "arn:aws:iam::1:role/backup"
YAML
}

# A bare "remote" plus a working clone, so push/fetch are exercised for real.
setup() {
  rm -rf "$work/remote" "$work/repo"
  git init -q --bare "$work/remote"
  git init -q "$work/repo"
  cd "$work/repo"
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  write_values "aaaaaaa"
  printf 'print("v1")\n' > app.py
  git add -A && git commit -q -m "initial"
  git remote add origin "$work/remote"
  git push -q -u origin HEAD:master
}

# ---- 1. first promotion creates the branch off the promoted commit ------------------------------
setup
src="$(git rev-parse HEAD)"
out="$(SOURCE_SHA="$src" TAG="bbbbbbb" bash "$SUT" 2>&1)" || fail "first promotion failed: $out"
grep -q "does not exist yet" <<<"$out" || fail "expected the create-branch path, got: $out"
git rev-parse --verify -q origin/release >/dev/null || fail "release was not pushed to the remote"
ok "the first promotion creates release and pushes it"

grep -q '^  tag: "bbbbbbb"$' "$VALUES_REL" || fail "the tag was not rewritten; file: $(cat "$VALUES_REL")"
ok "the image tag is rewritten and stays quoted"

# The first release commit must descend from the promoted master commit, not be an orphan -- an
# orphan branch cannot be diffed against master, which is half the point of this design.
git merge-base --is-ancestor "$src" HEAD || fail "the first release commit does not descend from master"
ok "release shares history with master rather than being an orphan"

# ---- 2. digests are written into the digests block, and only there ------------------------------
setup
src="$(git rev-parse HEAD)"
D="backend=sha256:aaa worker=sha256:bbb nginx=sha256:ccc backup=sha256:ddd"
out="$(SOURCE_SHA="$src" TAG="ccccccc" DIGESTS="$D" bash "$SUT" 2>&1)" || fail "promotion with digests failed: $out"
grep -q '^    backend: "sha256:aaa"$' "$VALUES_REL" || fail "backend digest missing: $(cat "$VALUES_REL")"
grep -q '^    backup: "sha256:ddd"$'  "$VALUES_REL" || fail "backup digest missing"
ok "all four digests land inside the digests: block"

# `backup:` is also a TOP-LEVEL key in this file, carrying roleArn. A rewrite that pattern-matched a
# bare key name instead of tracking the digests block would corrupt it.
grep -q '^backup:$' "$VALUES_REL" || fail "the top-level backup: section was destroyed by the rewrite"
grep -q '^  roleArn: "arn:aws:iam::1:role/backup"$' "$VALUES_REL" || fail "backup.roleArn was corrupted"
ok "an identically-named key OUTSIDE the digests block is left alone"

# ---- 3. the release tree equals the master tree, plus the pins ----------------------------------
setup
src="$(git rev-parse HEAD)"
SOURCE_SHA="$src" TAG="ddddddd" bash "$SUT" >/dev/null 2>&1 || fail "promotion failed"
diff_files="$(git diff --name-only "$src" HEAD)"
[ "$diff_files" = "$VALUES_REL" ] || fail "release should differ from master ONLY in values.yaml, got: $diff_files"
ok "release differs from the promoted master commit in values.yaml and nothing else"

# ---- 4. a SECOND promotion picks up new master content, with no conflict ------------------------
git checkout -q master
printf 'print("v2")\n' > app.py
mkdir -p charts/voteball && printf 'newfile\n' > newthing.txt
write_values "aaaaaaa"
git add -A && git commit -q -m "feat: v2"
git push -q origin master
src2="$(git rev-parse HEAD)"
out="$(SOURCE_SHA="$src2" TAG="eeeeeee" bash "$SUT" 2>&1)" || fail "second promotion failed: $out"
grep -q 'print("v2")' app.py || fail "release did not pick up master's new content"
[ -f newthing.txt ] || fail "release did not pick up a file added on master"
grep -q '^  tag: "eeeeeee"$' "$VALUES_REL" || fail "the second promotion did not rewrite the tag"
ok "a later promotion takes master's new content with no merge conflict"

# ---- 5. DELETIONS propagate -- the case `git checkout <sha> -- .` gets wrong --------------------
git checkout -q master
git rm -q newthing.txt
git commit -q -m "chore: drop newthing"
git push -q origin master
src3="$(git rev-parse HEAD)"
SOURCE_SHA="$src3" TAG="fffffff" bash "$SUT" >/dev/null 2>&1 || fail "third promotion failed"
[ -f newthing.txt ] && fail "a file deleted on master is still present on release (read-tree regressed to checkout -- .)"
ok "a file deleted on master disappears from release"

# ---- 6. history is append-only, so --force is never needed --------------------------------------
count="$(git rev-list --count HEAD)"
[ "$count" -ge 4 ] || fail "expected release history to accumulate, got $count commits"
git merge-base --is-ancestor "$(git rev-parse origin/release~1)" origin/release \
  || fail "release history is not append-only -- a force push would be required"
ok "release history is append-only (no force push is ever needed)"

# ---- 7. re-promoting the SAME commit at the same tag is a clean no-op ---------------------------
out="$(SOURCE_SHA="$src3" TAG="fffffff" bash "$SUT" 2>&1)" || fail "an idempotent re-promotion must exit 0: $out"
grep -q "nothing to commit" <<<"$out" || fail "a repeat promotion should report no change, got: $out"
ok "re-promoting the same commit at the same tag commits nothing and exits 0"

# ---- 7b. an UNTRACKED workspace file must never reach the release branch ------------------------
# Live CD #1 on 2026-08-23 committed `image-digests.tsv` -- an artifact the Input Validation stage
# writes into the agent workspace -- onto `release`, because this script used `git add -A`. CD #2 then
# died on `git checkout -B release` with "untracked working tree files would be overwritten", since
# the file existed on both sides. One stray build artifact had made the deployed branch
# un-promotable.
setup
git checkout -q master
src="$(git rev-parse HEAD)"
printf 'backend\tsha256:deadbeef\n' > image-digests.tsv     # untracked, exactly as CI leaves it
printf 'scratch\n' > some-other-artifact.log
SOURCE_SHA="$src" TAG="1111111" bash "$SUT" >/dev/null 2>&1 || fail "promotion failed with untracked files present"
git ls-tree --name-only HEAD | grep -q 'image-digests.tsv' \
  && fail "an untracked build artifact was committed to the release branch (git add -A regressed)"
git ls-tree --name-only HEAD | grep -q 'some-other-artifact.log' \
  && fail "an untracked file was committed to the release branch (git add -A regressed)"
ok "untracked workspace artifacts are NOT committed to the release branch"

# ...and the promotion must still work a SECOND time with those files still lying around, which is
# the actual failure CD #2 hit.
SOURCE_SHA="$src" TAG="2222222" bash "$SUT" >/dev/null 2>&1 \
  || fail "a second promotion with untracked files present failed -- this is the CD #2 checkout abort"
grep -q '^  tag: "2222222"$' "$VALUES_REL" || fail "the second promotion did not rewrite the tag"
ok "a repeat promotion still works with untracked artifacts in the workspace"

rm -f image-digests.tsv some-other-artifact.log

# ---- 8. REFUSALS ---------------------------------------------------------------------------------
out="$(SOURCE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" TAG="ggggggg" bash "$SUT" 2>&1)" \
  && fail "promoting a nonexistent commit must fail"
grep -q "is not a commit" <<<"$out" || fail "the error should say the commit is unknown, got: $out"
ok "a SOURCE_SHA that is not a commit is refused"

# A drifted tag: line must be caught, not silently ignored. This is the exact class of bug that let
# CD write unquoted tags for weeks in August -- awk exits 0 whether or not any rule fired.
setup
git checkout -q master
sed -i 's/^  tag: "aaaaaaa"$/  tag: aaaaaaa/' "$VALUES_REL"     # unquoted -- the 2026-08-04 shape
git commit -q -am "break the tag line"
git push -q origin master
src="$(git rev-parse HEAD)"
out="$(SOURCE_SHA="$src" TAG="hhhhhhh" bash "$SUT" 2>&1)" && fail "an unrewritable tag: line must fail the promotion"
grep -q "does not name hhhhhhh" <<<"$out" || fail "the error should say the tag did not land, got: $out"
ok "a tag: line whose shape drifted fails loudly instead of promoting the old version"

# The same for digests: a missing digests block must not be silently skipped, or CD would report a
# digest-pinned deploy while shipping tags.
setup
git checkout -q master
# sed, not python3: this test lives in GIT_GROUP and runs in the jnlp container, which has git and
# no python3 at all (see run-ci-suite.sh). Deletes the digests: block up to the next top-level key.
sed -i '/^  digests:$/,/^config:$/{/^config:$/!d}' "$VALUES_REL"
git commit -q -am "drop the digests block"
git push -q origin master
src="$(git rev-parse HEAD)"
out="$(SOURCE_SHA="$src" TAG="iiiiiii" DIGESTS="backend=sha256:zzz" bash "$SUT" 2>&1)" \
  && fail "a missing digests block must fail when digests were requested"
grep -q "did not land" <<<"$out" || fail "the error should say the digest did not land, got: $out"
ok "a requested digest that cannot be written fails loudly rather than shipping tags"

# ---- 9. THE CI -> CD SOURCE-COMMIT RACE (2026-08-28) --------------------------------------------
# Jenkinsfile-cd's Promote stage used to run `SOURCE_SHA="$(git rev-parse HEAD)"` in its OWN
# workspace. IMAGE_TAG is sampled by application-ci when it triggers CD; the CD workspace checkout
# happens later. Any push landing on master in that gap made the two name different commits, and
# because promotion is a `git read-tree -u --reset` of SOURCE_SHA, the release branch then carried
# the LATER commit's ENTIRE TREE -- chart included -- pinned to images that were never built from it.
# Observed live: `release: cfb579a (image tag edd3d9b)`.
#
# This is the 2026-08-21 queued-build race (which made should-skip-build.sh range-aware) one stage
# further down: sampling the branch tip instead of the commit the build was triggered for.
#
# 9a is the CONSEQUENCE, pinned as a contract on the script: given a source commit and a master that
# has moved past it, the release tree must be the source commit's.
setup
git checkout -q master
built="$(git rev-parse HEAD)"                       # what application-ci built and tagged
printf 'print("v1")\n'   > app.py                   # unchanged, for clarity
printf 'replicas: 99\n'  > charts/voteball/racer.yaml   # the chart change that raced in AFTER the build
printf 'print("later")\n' > later.py
git add -A && git commit -q -m "chart: a commit that landed while CI was busy"
git push -q origin master
tip="$(git rev-parse HEAD)"
[ "$built" != "$tip" ] || fail "the fixture did not actually advance master"

SOURCE_SHA="$built" TAG="3333333" bash "$SUT" >/dev/null 2>&1 || fail "promoting the built commit failed"
[ -f charts/voteball/racer.yaml ] && \
  fail "release carries the CHART of a commit whose images were never built -- promote used the branch tip, not the source commit"
[ -f later.py ] && fail "release carries the tree of the branch tip rather than the promoted commit"
git diff --quiet "$built" HEAD -- app.py || fail "release content does not match the promoted commit"
ok "promotion takes the tree of the PASSED commit, not the branch tip, when master has moved on"

# ...and the commit message must name the commit that was promoted, not the tip. `release: <tip>
# (image tag <built>)` is the exact live signature of the defect.
subject="$(git log -1 --format=%s)"
[ "$subject" = "release: $(git rev-parse --short "$built") (image tag 3333333)" ] \
  || fail "the release commit names the wrong source commit: $subject"
ok "the release commit message names the promoted commit, not the workspace tip"

# 9b. An ABSENT source commit must stop the promotion, never fall back to the tip. Both shapes:
# unset, and set to something that is not a commit here (the latter is case 8 above; this asserts the
# extra property that release is left untouched).
before="$(git rev-parse origin/release)"
out="$(SOURCE_SHA="" TAG="4444444" bash "$SUT" 2>&1)" && fail "an empty SOURCE_SHA must fail, not default to HEAD"
grep -q "SOURCE_SHA" <<<"$out" || fail "the error should name SOURCE_SHA, got: $out"
out="$(TAG="4444444" bash "$SUT" 2>&1)" && fail "an unset SOURCE_SHA must fail, not default to HEAD"
grep -q "SOURCE_SHA" <<<"$out" || fail "the error should name SOURCE_SHA, got: $out"
git fetch -q origin release
[ "$(git rev-parse origin/release)" = "$before" ] \
  || fail "a refused promotion still moved the release branch"
ok "an empty or unset SOURCE_SHA refuses to promote and leaves release untouched"

# ---- 10. THE PIPELINE SIDE of the same defect -----------------------------------------------------
# The script above has always taken SOURCE_SHA as an input and has always refused a bad one. The bug
# was entirely in what Jenkinsfile-cd PASSED it, which no behavioural test of this script can reach --
# so these are static assertions on the two Jenkinsfiles and on the JCasC job definition. They are the
# checks that actually failed before the 2026-08-28 fix.
#
# Static-grep checks earn their keep only if they can fail, so each pattern below was confirmed
# against the pre-fix files: `SOURCE_SHA="$(git rev-parse` was present, and all four positive
# patterns were absent.
CD="$ROOT/Jenkinsfile-cd"
CI="$ROOT/Jenkinsfile-ci"
JC="$ROOT/ci/jenkins/jenkins.yaml"

grep -qF 'SOURCE_SHA="$(git rev-parse' "$CD" \
  && fail "Jenkinsfile-cd derives SOURCE_SHA from its own workspace HEAD again -- that is the CI->CD race"
ok "Jenkinsfile-cd does not derive SOURCE_SHA from git rev-parse HEAD"

grep -qF "string(name: 'SOURCE_SHA'" "$CD" \
  || fail "Jenkinsfile-cd declares no SOURCE_SHA parameter"
ok "Jenkinsfile-cd declares a SOURCE_SHA parameter"

# Validated the way IMAGE_TAG is: rejected empty, and required to look like a commit SHA. Without
# both, an absent parameter would reach promote-to-release.sh and only be caught there -- after the
# release branch has been checked out under it.
grep -qF 'params.SOURCE_SHA?.trim()' "$CD" \
  || fail "Jenkinsfile-cd does not reject an empty SOURCE_SHA in Input Validation"
grep -qF 'params.SOURCE_SHA ==~ /^[0-9a-f]{7,40}$/' "$CD" \
  || fail "Jenkinsfile-cd does not check SOURCE_SHA's shape the way it checks IMAGE_TAG's"
ok "Jenkinsfile-cd validates SOURCE_SHA in Input Validation, exactly as it validates IMAGE_TAG"

grep -qF "string(name: 'SOURCE_SHA'," "$CI" \
  || fail "Jenkinsfile-ci does not pass SOURCE_SHA to application-cd -- CD would refuse every deploy"
grep -qF 'value: env.GIT_COMMIT_SHA' "$CI" \
  || fail "Jenkinsfile-ci passes something other than the commit it built as SOURCE_SHA"
ok "Jenkinsfile-ci passes the commit it built (GIT_COMMIT_SHA) as SOURCE_SHA"

# The rollback re-trigger is a THIRD caller of application-cd and needs the parameter too: without it
# the rollback build fails Input Validation, so a failed deploy would leave production broken with no
# rollback at all -- a strictly worse outcome than the bug being fixed.
grep -qF "value: env.SOURCE_SHA" "$CD" \
  || fail "Jenkinsfile-cd's rollback re-trigger does not pass SOURCE_SHA -- every rollback would be refused"
ok "the rollback re-trigger passes SOURCE_SHA too"

# JCasC reloads the job definition from scratch on every controller restart (roughly daily on Spot)
# and drops any parameter this block does not declare. Missed once already with ROLLBACK_DEPTH.
grep -qF "stringParam('SOURCE_SHA'" "$JC" \
  || fail "ci/jenkins/jenkins.yaml does not declare SOURCE_SHA for application-cd -- a JCasC reload would drop it"
ok "the JCasC application-cd job declares SOURCE_SHA, so a reload cannot drop it"

echo "PASS: $(basename "$0") -- $pass checks"
