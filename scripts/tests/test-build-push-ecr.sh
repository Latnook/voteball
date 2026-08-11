#!/usr/bin/env bash
# Offline test for build-push-ecr.sh's dirty-tree guard. Same pattern as test-deploy-env.sh: the
# script itself is never run (it would reach `docker build` and a real ECR push), so the guard block
# is extracted from the live file and executed against throwaway git repos.
#
# Extracting rather than restating is the whole point, and this file exists because of a near-miss:
# on 2026-08-11 revision 18's seed.sql was uncommitted when deploy.sh reached the image step, which
# would have published it under a commit SHA that does not contain it. A hand-written copy of the
# guard would keep passing even if someone deleted the real one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Pull the guard out of the live script, between its BEGIN/END markers. If the markers or the block
# disappear, the extraction is empty and this fails -- which is the correct outcome.
awk '/^# --- BEGIN dirty-tree guard ---$/,/^# --- END dirty-tree guard ---$/' \
  "$ROOT/scripts/build-push-ecr.sh" > "$work/guard.sh"
[ -s "$work/guard.sh" ] || fail "could not find the dirty-tree guard block in scripts/build-push-ecr.sh"
grep -q 'git status --porcelain' "$work/guard.sh" \
  || fail "guard no longer inspects 'git status --porcelain'"

# The guard must sit before BOTH the remote-state read (`tf_out`, an S3 round-trip) and the ECR
# login, so a refusal costs no network at all. Line order in the real file is the only way to check
# this, and it is worth checking: a guard that still works but runs late turns a free local failure
# into a slow one, which is how "fail fast" quietly rots.
guard_line="$(grep -n '^# --- BEGIN dirty-tree guard ---$' "$ROOT/scripts/build-push-ecr.sh" | cut -d: -f1)"
tfout_line="$(grep -n 'tf_out ecr_registry' "$ROOT/scripts/build-push-ecr.sh" | head -1 | cut -d: -f1)"
login_line="$(grep -n 'aws ecr get-login-password' "$ROOT/scripts/build-push-ecr.sh" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$tfout_line" ] && [ -n "$login_line" ] \
  || fail "could not locate the guard, tf_out and ECR login lines"
[ "$guard_line" -lt "$tfout_line" ] \
  || fail "guard runs AFTER the terraform-state read (line $guard_line vs $tfout_line)"
[ "$guard_line" -lt "$login_line" ] \
  || fail "guard runs AFTER the ECR login (line $guard_line vs $login_line) -- it must run first"
ok "guard precedes both the terraform-state read and the ECR login"

# Run the guard in a throwaway repo. TAG is set here because the real script computes it just above
# the block; the probe reports the guard's exit status and the tag it ended up with.
probe() {
  ( cd "$work/repo" && \
    ALLOW_DIRTY_BUILD="${1:-}" bash -c '
      set -euo pipefail
      TAG="$(git rev-parse --short HEAD)"
      . "'"$work"'/guard.sh"
      echo "TAG=${TAG}"
    ' 2>"$work/err" ; echo "EXIT=$?" )
}

rm -rf "$work/repo"; mkdir -p "$work/repo"
cd "$work/repo"
git init -q .
git config user.email t@t; git config user.name t
echo one > tracked.txt
git add tracked.txt
git commit -qm init
sha="$(git rev-parse --short HEAD)"
cd "$ROOT"

echo "--- clean tree builds normally ---"
out="$(probe)"
grep -q "EXIT=0" <<<"$out" || fail "clean tree was rejected: $out $(cat "$work/err")"
grep -q "TAG=${sha}$" <<<"$out" || fail "clean tree should keep the plain SHA, got: $out"
ok "clean tree passes and keeps tag '${sha}'"

echo "--- modified tracked file is refused ---"
echo two > "$work/repo/tracked.txt"
out="$(probe)"
grep -q "EXIT=1" <<<"$out" || fail "dirty tree was NOT refused: $out"
grep -q "refusing to build" "$work/err" || fail "no explanatory error, got: $(cat "$work/err")"
ok "modified tracked file is refused with a non-zero exit"

echo "--- untracked file is refused too (docker build context includes it) ---"
git -C "$work/repo" checkout -q -- tracked.txt
echo stray > "$work/repo/untracked.txt"
out="$(probe)"
grep -q "EXIT=1" <<<"$out" || fail "untracked file was NOT refused: $out"
ok "untracked file is refused"

echo "--- gitignored file does NOT block (it cannot reach the image) ---"
rm -f "$work/repo/untracked.txt"
printf 'ignored.txt\n' > "$work/repo/.gitignore"
git -C "$work/repo" add .gitignore
git -C "$work/repo" commit -qm ignore
sha="$(git -C "$work/repo" rev-parse --short HEAD)"
echo secret > "$work/repo/ignored.txt"
out="$(probe)"
grep -q "EXIT=0" <<<"$out" || fail "gitignored file wrongly blocked the build: $out $(cat "$work/err")"
ok "gitignored file is correctly ignored"

echo "--- ALLOW_DIRTY_BUILD=1 proceeds but marks the tag ---"
echo three > "$work/repo/tracked.txt"
out="$(probe 1)"
grep -q "EXIT=0" <<<"$out" || fail "override did not allow the build: $out $(cat "$work/err")"
grep -q "TAG=${sha}-dirty$" <<<"$out" \
  || fail "override must suffix the tag so it cannot claim to be a commit, got: $out"
ok "override builds and tags '${sha}-dirty' rather than a bare SHA"

echo
echo "PASS ($pass checks)"
