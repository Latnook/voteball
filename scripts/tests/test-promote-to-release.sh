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

echo "PASS: $(basename "$0") -- $pass checks"
