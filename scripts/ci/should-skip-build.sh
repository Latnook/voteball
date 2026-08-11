#!/usr/bin/env bash
# G2 -- Jenkins has NO native [skip ci] support; that is a GitHub Actions feature.
#
# Without this guard, the tag-bump commit the pipeline itself pushes fires the webhook, Jenkins
# builds that new SHA, pushes images, bumps the tag, commits again -- an unbounded build loop that
# consumes ECR storage and continuously rolls production pods.
#
# Prints "skip" or "build". Still fails safe -- a spurious skip costs one manual rebuild while a
# spurious build costs a loop -- but the marker is matched ONLY in the SUBJECT LINE, not the body.
#
# It used to match anywhere in the message, and that misfired on 2026-08-11: two commits whose bodies
# *described* this guard ("the [skip ci] loop guard") skipped themselves. Both were CI changes, so
# the pipeline silently declined to test the very code that tests the pipeline, and reported
# NOT_BUILT -- which reads exactly like a pass unless you go looking. The assumed cost of a spurious
# skip, "one manual rebuild", understated it: the real cost was believing something had been verified
# when it never ran.
#
# Narrowing to the subject line loses no loop protection. Jenkinsfile-cd writes its tag bump with a
# single -m ("ci: image tag $TAG [skip ci]"), so the marker is always in the subject; test-ci-guards.sh
# pins that exact string. If CD ever moves the marker into a body line, that test fails loudly rather
# than the loop guard failing silently.
set -euo pipefail

msg="${1-}"
subject="${msg%%$'\n'*}"

case "$subject" in
  *"[skip ci]"*) echo "skip" ;;
  *)             echo "build" ;;
esac
