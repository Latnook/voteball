#!/usr/bin/env bash
# deploy.sh step 9's commit SUBJECT for charts/voteball/values.yaml.
#
# WHY THIS IS TESTED. This file's git history is the rollback mechanism -- scripts/ci/previous-tag.sh
# walks `git log -p` over it to find the tag to roll back to -- so the log is read by humans under
# time pressure. Until 2026-09-09 every one of these commits carried the same fixed sentence, which
# recorded that a deploy happened and nothing about what it deployed.
#
# The subject is now COMPUTED, and a computed subject can be wrong in the way this repo keeps
# relearning: silently, and looking fine. An empty capture would produce "deploy: image tag  -> "
# and no shell would complain. So both branches and every degenerate input are pinned here.
#
# Offline by construction: values_commit_message takes file CONTENT, not paths, so nothing here
# needs a git repo, a cluster or AWS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Pull the function out of the LIVE deploy.sh rather than restating it. A restated copy would pass
# happily while the real script did something else -- exactly how scripts/tests/test-deploy-env.sh
# was written, and for the same reason: a copy tests the copy.
awk '/^  # --- values-commit-message: BEGIN/,/^  # --- values-commit-message: END/' \
    "$ROOT/scripts/deploy.sh" > "$work/block.sh"
[ -s "$work/block.sh" ] || fail "could not extract the values-commit-message block from scripts/deploy.sh"
grep -q 'values_commit_message()' "$work/block.sh" \
  || fail "the extracted block no longer defines values_commit_message"
ok "extracted the block from the live deploy.sh"

# shellcheck disable=SC1090
. "$work/block.sh"

vals() { printf 'image:\n  tag: "%s"\n  pullPolicy: IfNotPresent\n' "$1"; }

got() { values_commit_message "$1" "$2"; }

# ---- the tag moved: the whole point ----------------------------------------------------------
out="$(got "$(vals 05ac336)" "$(vals 2ac616c)")"
[ "$out" = "deploy: image tag 05ac336 -> 2ac616c" ] \
  || fail "tag change: expected 'deploy: image tag 05ac336 -> 2ac616c', got '$out'"
ok "a tag change names both tags"

# ---- the tag did NOT move: only the four digests were pinned ----------------------------------
# deploy.sh pins digests in the same step, so values.yaml can change with the tag standing still.
# Calling that a tag change would be a lie in the log; calling it nothing would lose the commit.
out="$(got "$(vals 2ac616c)" "$(vals 2ac616c)")"
[ "$out" = "deploy: pin image digests for 2ac616c" ] \
  || fail "digest-only change: expected the digest-pin subject, got '$out'"
ok "an unchanged tag reports a digest pin, not a tag move"

# ---- degenerate inputs must never produce a subject with a hole in it --------------------------
# The failure this guards is silent: "deploy: image tag  -> " is a valid commit subject.
out="$(got "" "$(vals 2ac616c)")"
[ "$out" = "deploy: image tag 2ac616c" ] \
  || fail "no previous tag: expected a single-tag subject, got '$out'"
ok "a missing previous tag does not render an empty arrow"

out="$(got "$(vals 05ac336)" "")"
[ "$out" = "deploy: sync values.yaml from Terraform outputs" ] \
  || fail "no new tag: expected the generic subject, got '$out'"
ok "an unreadable new tag falls back to the generic subject"

case "$(got "$(vals 05ac336)" "$(vals 2ac616c)")" in
  *"  "*|*"-> "|*" ->") fail "subject contains an empty field" ;;
esac
ok "no subject renders an empty field"

# ---- the QUOTED-tag contract, shared with previous-tag.sh and current-release-tag.sh ------------
# An unquoted `tag: abc1234` is the 2026-08-04 escaping bug's signature. Accepting it here would put
# a confident, wrong tag in the log for a values.yaml that is already malformed.
unquoted="$(printf 'image:\n  tag: 2ac616c\n')"
out="$(got "$(vals 05ac336)" "$unquoted")"
[ "$out" = "deploy: sync values.yaml from Terraform outputs" ] \
  || fail "an UNQUOTED tag must not be captured (2026-08-04 bug signature), got '$out'"
ok "an unquoted tag is refused, not guessed at"

# A trailing comment must not be swallowed into the tag -- same capture rule as previous-tag.sh,
# which had to grow [^"]* for exactly this.
#
# The comment MUST contain its own quote character. With a quote-free comment a greedy (.*)" and the
# correct ([^"]*)" produce identical output, so the fixture would pass against the very bug it names
# -- confirmed by mutation on 2026-09-09: swapping in the greedy capture was NOT caught until this
# fixture grew the inner quotes.
commented="$(printf 'image:\n  tag: "2ac616c"   # pushed by deploy.sh step 9 (see "previous-tag.sh")\n')"
out="$(got "$(vals 05ac336)" "$commented")"
[ "$out" = "deploy: image tag 05ac336 -> 2ac616c" ] \
  || fail "a trailing comment must be stripped from the tag, got '$out'"
ok "a trailing comment is stripped from the captured tag"

# ---- the marker that would break the Guard must never appear ------------------------------------
# deploy.sh has a long comment explaining why: the Guard reads HEAD's subject and aborts the WHOLE
# build, so a marker here could abort a build that was carrying somebody else's app-code commit.
for a in "$(vals 05ac336)" "" "$(vals 2ac616c)"; do
  for b in "$(vals 2ac616c)" ""; do
    case "$(got "$a" "$b")" in *"[skip ci]"*) fail "subject must never carry [skip ci]" ;; esac
  done
done
ok "no branch emits [skip ci]"

echo "PASS: $pass assertions"
