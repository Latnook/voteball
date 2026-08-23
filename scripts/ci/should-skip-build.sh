#!/usr/bin/env bash
# G2 -- Jenkins has NO native [skip ci] support; that is a GitHub Actions feature.
#
# Without this guard, a tag-bump commit the pipeline itself pushes fires the webhook, Jenkins builds
# that new SHA, pushes images, bumps the tag, commits again -- an unbounded build loop that consumes
# ECR storage and continuously rolls production pods.
#
# TWO FORMS:
#   should-skip-build.sh "<commit message>"     -- one commit. Skip iff its SUBJECT carries the marker.
#   should-skip-build.sh --subjects             -- one commit SUBJECT per line on stdin. Skip iff the
#                                                  input is non-empty AND *every* line carries it.
#
# Prints "skip" or "build".
#
# WHY THE RANGE FORM EXISTS (2026-08-23, Task 4 review finding P1). The single-message form reads the
# branch TIP and nothing else, so it cannot distinguish "the tip is a promotion commit and nothing
# else is pending" from "the tip is a promotion commit and real source commits are hiding behind it".
# The second case happened for real on 2026-08-21: CI #1 was building b09a05d when a558113 was pushed
# and queued; CD then pushed its promotion commit e9e5c7a at 15:45:59, and the queued build began its
# checkout at 15:46:46 -- 45 seconds too late. Jenkins checks out the branch TIP at start time, not
# the commit that triggered the build, so build #2 saw e9e5c7a, matched the marker, and reported
# NOT_BUILT. a558113 was never built by that build or any later one: it sits BEHIND the tip, so no
# subsequent build's changeset contains it either. NOT_BUILT reads exactly like a pass.
#
# Feeding the whole range since the last SUCCESSFUL build fixes it without weakening the loop guard:
# a range holding only promotion commits still skips, and a range holding even one real commit
# builds. Jenkins' GIT_PREVIOUS_SUCCESSFUL_COMMIT is the right base precisely because a NOT_BUILT run
# does not advance it, so a missed commit stays inside the range until something actually builds it.
#
# The release-branch change landing alongside this (docs/design/2026-08-23-release-branch-and-digest-
# design.md) removes the race at its root by taking CD's promotion commits off `master` entirely.
# This stays anyway: deploy.sh step 9 still commits to master, and a guard that is only correct while
# a separate design decision holds is a guard waiting to be wrong.
#
# STILL FAILS SAFE toward skipping when it cannot tell (no input, single-message form), because a
# spurious skip costs one manual rebuild and a spurious build costs an unbounded billable loop. But
# the 2026-08-11 incident showed "one manual rebuild" understates it -- the real cost is believing
# something was verified when it never ran -- which is why the marker is matched ONLY in the SUBJECT
# LINE. It used to match anywhere in the message, and two commits whose BODIES described this guard
# ("the [skip ci] loop guard") skipped themselves; both were CI changes, so the pipeline silently
# declined to test the very code that tests the pipeline.
#
# Narrowing to the subject loses no loop protection: Jenkinsfile-cd writes its promotion with a single
# -m, so the marker is always in the subject, and test-ci-guards.sh pins that exact string. If CD ever
# moves the marker into a body line, that test fails loudly rather than the loop guard failing
# silently.
#
# Deliberately does NOT shell out to git: it must stay runnable in the `python` CI container, which
# has no git at all (see run-ci-suite.sh). The caller computes the range and pipes the subjects in.
set -euo pipefail

MARKER="[skip ci]"

has_marker() {   # has_marker <subject>
  case "$1" in
    *"$MARKER"*) return 0 ;;
    *)           return 1 ;;
  esac
}

if [ "${1-}" = "--subjects" ]; then
  saw_any=0
  saw_unmarked=0
  while IFS= read -r subject || [ -n "$subject" ]; do
    # A blank line is not a commit. `git log --format=%s` emits none, but a caller assembling the
    # list by other means can, and treating one as an unmarked commit would build on every run.
    [ -n "${subject//[[:space:]]/}" ] || continue
    saw_any=1
    has_marker "$subject" || saw_unmarked=1
  done

  # No commits in the range: nothing to skip over. Build. This cannot reopen the loop -- if CD had
  # pushed a promotion commit it would be IN the range, so an empty range means the tip is already
  # the last thing that built.
  if [ "$saw_any" = 0 ]; then echo "build"; exit 0; fi

  if [ "$saw_unmarked" = 1 ]; then echo "build"; else echo "skip"; fi
  exit 0
fi

msg="${1-}"
subject="${msg%%$'\n'*}"

if has_marker "$subject"; then echo "skip"; else echo "build"; fi
